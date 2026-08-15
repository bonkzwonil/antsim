;;;; tests/render.lisp — renderer tests.
;;;;
;;;; Split from the core suite because these need cl-opengl loaded, and
;;;; the GL ones need a driver.  The PNG tests do not, and run anywhere.
;;;;
;;;; GL tests *skip* rather than fail when no context can be created, so
;;;; the suite stays useful on a machine without a GPU.  The consequence
;;;; is that a green run here does not by itself mean the renderer was
;;;; verified — `make test-render` (which wraps the guix GPU shell) is
;;;; what proves that, and it says so in its own output.

(defpackage #:antsim/render-test
  (:use #:cl #:fiveam)
  (:export #:render))

(in-package #:antsim/render-test)

(def-suite render)
(in-suite render)

(defun test-png-path (name)
  (merge-pathnames name (uiop:temporary-directory)))

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
      (is (= ctype 2)))                 ; 2 = truecolour RGB
    (delete-file path)))

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
      (is (= ctype 6)))                 ; 6 = truecolour + alpha
    (delete-file path)))

;;; ------------------------------------------------------------------- GL

(defvar *gl-available*
  (handler-case
      (let ((c (ant:make-headless-context :width 32 :height 32)))
        (ant:destroy-gl-context c)
        t)
    (error () nil)))

(defmacro with-gl-or-skip (&body body)
  `(if *gl-available*
       (progn ,@body)
       (skip "No GL context available (run under: guix shell nvda@580 -- ...)")))

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
               1000))
        (delete-file path)))))

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
