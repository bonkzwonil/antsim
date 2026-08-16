;;;; tests/render.lisp — renderer tests.
;;;;
;;;; Split from the core suite because these need cl-opengl loaded, and
;;;; the GL ones need a driver.  The PNG tests do not, and run anywhere.
;;;;
;;;; Skipping is the last resort, not the plan.  Mesa's llvmpipe provides
;;;; a 4.5 core context in software, so `make test-render-mesa` runs this
;;;; entire suite on a machine with no GPU at all — slowly, which does not
;;;; matter for a few small frames.  A skip therefore means the
;;;; environment is misconfigured, not that the machine is modest.
;;;;
;;;; Which GL actually ran is printed when the suite loads, because "the
;;;; render tests passed" is not a useful statement on its own: passing on
;;;; llvmpipe and passing on the RTX 3070 are different claims, and a log
;;;; that does not say which one it made cannot be read later.

(defpackage #:antsim/render-test
  (:use #:cl #:fiveam)
  (:export #:render))

(in-package #:antsim/render-test)

(def-suite render)
(in-suite render)

;;; Frames the tests draw are kept rather than deleted.  This is a
;;; graphics project: when a render test fails, the first question is
;;; always "what did it look like?", and a temporary file that has already
;;; been unlinked cannot answer it.  They are small, and out/ is ignored.
(defparameter *test-output-directory* #p"out/tests/")

(defun test-png-path (name)
  (merge-pathnames name (ensure-directories-exist *test-output-directory*)))

;;; ------------------------------------------------------------------ PNG

(defun decode-png-header (path)
  "(values width height bit-depth colour-type) read back from a PNG."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((sig (make-array 8 :element-type '(unsigned-byte 8))))
      (read-sequence sig in)
      (assert (equalp sig #(137 80 78 71 13 10 26 10)) () "Bad PNG signature")
      (dotimes (i 8) (read-byte in))    ; IHDR length + type
      (flet ((u32 () (let ((v 0)) (dotimes (i 4 v)
                                    (setf v (+ (* v 256) (read-byte in)))))))
        (let* ((w (u32)) (h (u32))
               (depth (read-byte in)) (ctype (read-byte in)))
          (values w h depth ctype))))))

(test png-roundtrip-header
  "The writer emits a well-formed header with the right dimensions."
  (let* ((w 7) (h 5)
         (px (make-array (* w h 3) :element-type '(unsigned-byte 8)))
         (path (test-png-path "antsim-png-test.png")))
    (dotimes (i (length px)) (setf (aref px i) (mod (* i 37) 256)))
    (ant:write-png path px w h :channels 3)
    (multiple-value-bind (rw rh depth ctype) (decode-png-header path)
      (is (= rw w))
      (is (= rh h))
      (is (= depth 8))
      (is (= ctype 2)))))               ; 2 = truecolour RGB

(test png-crc-and-adler-known-values
  "CRC32 and Adler32 against published test vectors.  A wrong checksum
produces a file that looks fine until something else tries to read it."
  (let ((abc (map '(simple-array (unsigned-byte 8) (*)) #'char-code "abc")))
    (is (= (ant:crc32 abc) #x352441C2))
    (is (= (ant:adler32 abc) #x024D0127))))

(test png-rgba-channel-type
  (let* ((w 3) (h 2)
         (px (make-array (* w h 4) :element-type '(unsigned-byte 8)
                                   :initial-element 200))
         (path (test-png-path "antsim-png-rgba.png")))
    (ant:write-png path px w h :channels 4)
    (multiple-value-bind (rw rh depth ctype) (decode-png-header path)
      (declare (ignore rw rh depth))
      (is (= ctype 6)))))               ; 6 = truecolour + alpha

;;; --------------------------------------------------- the ant mesh (§5.2)
;;;
;;; No GL needed: the mesh is arithmetic, and the vertex program is
;;; generated text.  Both can be wrong in ways that are silent on screen —
;;; an index off the end of the buffer draws whatever is next in memory,
;;; and a splice that emits nothing compiles into a shader that quietly
;;; uses zero for every leg.

(test ant-mesh-is-well-formed
  (let* ((m (ant:build-ant-mesh))
         (ix (ant:ant-mesh-index m))
         (nv (ant:ant-mesh-nvert m)))
    (is (plusp nv))
    (is (zerop (mod (length ix) 3)) "~d indices is not whole triangles"
        (length ix))
    (is (= (length ix) (ant:ant-mesh-nindex m)))
    (is (= (length (ant:ant-mesh-verts m)) (* nv ant:+ant-vertex-floats+)))
    (is (every (lambda (i) (< i nv)) ix)
        "an index points past the end of the vertex buffer")
    ;; a few dozen triangles, per §5.2 — this is a budget, not a detail
    (is (< 40 (/ (length ix) 3) 200) "~d triangles" (/ (length ix) 3))))

(test ant-mesh-lod-ranges-partition-the-draw
  "The simplified body-only ant of §5.2 is a *range* of the full one, not
a second mesh.  That is what makes it impossible for the two to disagree
about where the gaster is — and it only holds if the ranges line up."
  (let* ((m (ant:build-ant-mesh))
         (under (ant:ant-mesh-under-count m))
         (body (ant:ant-mesh-body-count m))
         (total (ant:ant-mesh-nindex m)))
    (is (plusp under) "nothing is drawn beneath the body — the legs are lost")
    (is (plusp body))
    (is (< (+ under body) total) "nothing is drawn over the body")
    (is (zerop (mod under 3)))
    (is (zerop (mod body 3)))))

(test ant-vertex-program-carries-the-skeleton
  "The shader's leg tables are spliced in from antmesh.lisp rather than
written twice.  If the splice ever emits nothing the shader still
compiles — every leg simply attaches at the origin — so the joint is
checked here rather than looked at."
  (let ((src ant:*ant-vertex-glsl*))
    (dolist (name '("LEG_HIP" "LEG_FOOT" "LEG_LEN" "LEG_KNEE" "LEG_PHASE"
                    "ANT_SCAPE" "PETIOLE_X" "GASTER_TIP_X"))
      (is (search name src) "~a is missing from the generated shader" name))
    ;; the first leg's hip, as it appears in *LEGS*
    (let ((hip (format nil "vec2(~,5f, ~,5f)"
                       (first (first ant:*legs*)) (second (first ant:*legs*)))))
      (is (search hip src) "~a did not reach the shader" hip))
    ;; six entries in the table, not one repeated
    (let* ((at (search "LEG_KNEE" src))
           (open (position #\( src :start (search "float[6](" src :start2 at)))
           (close (position #\) src :start open)))
      (is (= 5 (count #\, src :start open :end close))
          "LEG_KNEE is not a six-element table: ~a"
          (subseq src open (1+ close))))))

;;; ------------------------------------------------------------------- GL

(defvar *gl-backend* nil
  "GL-INFO from a probe context, or NIL if none could be created.")

(defvar *gl-available*
  (handler-case
      (ant:with-gl-traps-masked
        (let ((c (ant:make-headless-context :width 32 :height 32)))
          (unwind-protect (setf *gl-backend* (ant:gl-info))
            (ant:destroy-gl-context c))
          t))
    (error () nil)))

(test gl-backend-is-reported
  "Not an assertion about the renderer — it prints which GL stack the run
actually used.  \"The render tests passed\" is not a useful statement on
its own: passing on llvmpipe and passing on an RTX 3070 are different
claims, and a log that does not say which one it made cannot be read
later.  It reports at *run* time rather than load time because
`ql:quickload :silent t` discards anything printed while loading."
  (if *gl-available*
      (progn
        (format t "~&;; GL backend: ~a | ~a | ~a~%"
                (getf *gl-backend* :version)
                (getf *gl-backend* :renderer)
                (getf *gl-backend* :vendor))
        (is-true (stringp (getf *gl-backend* :version))))
      (progn
        (format t "~&;; GL backend: NONE — the GL tests below will skip. ~
                   `make test-render-mesa` runs them in software.~%")
        (skip "no GL backend to report"))))

(defmacro with-gl-or-skip (&body body)
  `(if *gl-available*
       (progn ,@body)
       (skip "No GL context available.  `make test-render-mesa` runs this ~
              suite in software (llvmpipe) and needs no GPU.")))

(test gl-context-is-4.5-core
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 64 :height 64)
      (let ((v (getf (ant:gl-info) :version)))
        ;; A NIL version here means GL resolved against a library that has
        ;; no current context — the failure src/render/preload.lisp exists
        ;; to prevent.  It is asserted rather than tolerated because it is
        ;; otherwise completely silent.
        (is-true (stringp v) "GL version is NIL — the libGL trap (README §5.4)")
        (is-true (and v (>= (length v) 3)))
        (let ((major (digit-char-p (char v 0)))
              (minor (digit-char-p (char v 2))))
          (is-true (or (> major 4) (and (= major 4) (>= minor 5)))
                   "GL ~a is older than the 4.5 core context we asked for" v))))))

(test gl-clears-to-a-known-colour
  "Clear an FBO and read it back: proves the context, the framebuffer and
the readback path, which a black frame would not."
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 64 :height 64)
      (ant:with-offscreen (o 64 64)
        (ant:bind-offscreen o)
        (gl:clear-color 0.25 0.5 0.75 1.0)
        (gl:clear :color-buffer-bit)
        (gl:finish)
        (let* ((px (ant:read-offscreen o))
               (i (* 3 (+ (* 32 64) 32))))
          (is (< (abs (- (aref px i) 64)) 2))
          (is (< (abs (- (aref px (+ i 1)) 128)) 2))
          (is (< (abs (- (aref px (+ i 2)) 191)) 2)))))))

(test gl-readback-handles-unaligned-widths
  "Pack alignment defaults to 4, which pads every row of an odd-width
image and shears the result.  Read a 7-px-wide target and check the last
pixel of a row is the colour we cleared to, not padding."
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 7 :height 5)
      (ant:with-offscreen (o 7 5)
        (ant:bind-offscreen o)
        (gl:clear-color 1.0 0.0 0.0 1.0)
        (gl:clear :color-buffer-bit)
        (gl:finish)
        (let ((px (ant:read-offscreen o)))
          (is (= (length px) (* 7 5 3)))
          (is (every (lambda (v) (member v '(0 255))) px))
          (dotimes (row 5)
            (let ((last (* 3 (+ (* row 7) 6))))
              (is (= 255 (aref px last)) "row ~d red channel sheared" row)
              (is (= 0 (aref px (+ last 1)))))))))))

;;; --------------------------------------------------- the M0 acceptance

(test smoke-frame-is-not-black
  "M0's definition of done.  The frame must contain real shading, so the
test asks for three things a broken pipeline cannot fake: a mean well
above black, many distinct luminances, and both dark and bright pixels."
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 240 :height 150)
      (ant:with-offscreen (o 240 150)
        (ant:draw-smoke-frame o)
        ;; kept on disk so a failure can be looked at, not just read about
        (ant:capture-offscreen o (test-png-path "smoke-frame-judged.png"))
        (let* ((px (ant:read-offscreen o))
               (n (floor (length px) 3))
               (sum 0) (distinct (make-hash-table :test #'eql))
               (dark 0) (bright 0))
          (dotimes (i n)
            (let ((l (round (+ (* 0.299 (aref px (* i 3)))
                               (* 0.587 (aref px (+ (* i 3) 1)))
                               (* 0.114 (aref px (+ (* i 3) 2)))))))
              (incf sum l)
              (setf (gethash l distinct) t)
              (cond ((< l 40) (incf dark))
                    ((> l 120) (incf bright)))))
          (let ((mean (/ (float sum) n)))
            (is (> mean 10.0) "frame mean luminance ~,1f — this is a black frame" mean))
          (is (> (hash-table-count distinct) 32)
              "only ~d distinct luminances — the shader drew a flat fill"
              (hash-table-count distinct))
          (is (> dark 0))
          (is (> bright 0) "nothing bright: the ants and food did not draw"))))))

(test smoke-frame-writes-a-png
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 160 :height 100)
      (let ((path (test-png-path "antsim-m0-smoke.png")))
        (ant:render-smoke-png path :width 160 :height 100)
        (multiple-value-bind (w h depth ctype) (decode-png-header path)
          (is (= w 160))
          (is (= h 100))
          (is (= depth 8))
          (is (= ctype 2)))
        (is (> (with-open-file (s path :element-type '(unsigned-byte 8))
                 (file-length s))
               1000))))))

(test smoke-frame-is-deterministic
  "Two draws of the same frame must be byte-identical.  Nothing in the
shader reads a clock, and nothing may start to."
  (with-gl-or-skip
    (ant:with-headless-gl (c :width 120 :height 80)
      (ant:with-offscreen (o 120 80)
        (ant:draw-smoke-frame o)
        (let ((a (ant:read-offscreen o)))
          (ant:draw-smoke-frame o)
          (is (equalp a (ant:read-offscreen o))))))))
