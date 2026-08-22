;;;; render/timelapse.lisp — a run as a sequence, and as one picture (§7, M6).
;;;;
;;;; The gallery (gallery.lisp) answers "what does it look like at twenty
;;;; minutes".  This answers the question the gallery cannot: *when* did
;;;; that happen, and what did it pass through on the way.  A trail
;;;; forming, a source running down, a colony growing — §5.5 lists all
;;;; three as things that move over minutes to an hour, which is exactly
;;;; the range where a still is misleading and watching in real time is
;;;; unaffordable.
;;;;
;;;; Two outputs from one run, and the second is the one that gets
;;;; committed:
;;;;
;;;;   frames        one PNG per sample, for feeding to ffmpeg or a
;;;;                 flipbook.  Large — png.lisp writes stored deflate
;;;;                 blocks by design (no dependency), so a 640x448 frame
;;;;                 is 860 kB whatever is in it.  Goes to out/, which is
;;;;                 gitignored, and is never a documentation artefact.
;;;;
;;;;   contact sheet every sample, downscaled, tiled into a single image
;;;;                 with its timestamp burnt in.  One file, committable,
;;;;                 and it reads as a sequence in a way a directory of
;;;;                 360 files does not.  §4.1's file map has been
;;;;                 promising "contact sheets" since M1.
;;;;
;;;; The expensive things — the EGL context, five linked shader programs,
;;;; the ant mesh, the framebuffer — are built once and reused for every
;;;; frame.  RENDER-WORLD-PNG builds all of them per call, which is right
;;;; for one still and would dominate the wall clock of a hundred.

(in-package #:antsim)

(defparameter *timelapse-directory* #p"out/timelapse/"
  "Where frames go.  Under out/ because out/ is gitignored: a time-lapse
is hundreds of megabytes of intermediate, and the committed artefact is
the contact sheet.")

;;; --------------------------------------------------------------------
;;; The contact sheet
;;; --------------------------------------------------------------------

(defstruct (sheet (:constructor %make-sheet))
  "A grid of downscaled frames being filled in one frame at a time.

Held as one image rather than a list of frames because a list of frames
is the thing this exists to avoid: 360 frames at 640x448 is 310 MB of
PNG on disk and about the same in memory.  The sheet is allocated once,
at its final size, and each frame is averaged down into its tile as it
arrives and then dropped."
  (pixels nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (tile-w 0 :type fixnum)
  (tile-h 0 :type fixnum)
  (columns 1 :type fixnum)
  (gutter 0 :type fixnum)
  (scale 1 :type fixnum)
  (n 0 :type fixnum))

(defun make-sheet (frames frame-w frame-h &key (columns 6) (scale 4) (gutter 4))
  "A sheet with room for FRAMES tiles, each FRAME-W/SCALE wide.

SCALE is an integer divisor rather than an arbitrary ratio because the
downscale is a box average over exactly SCALE x SCALE source pixels: at
an integer factor that is both the correct filter and a trivial one, and
at a non-integer factor it is neither."
  (let* ((tw (max 1 (floor frame-w scale)))
         (th (max 1 (floor frame-h scale)))
         (rows (max 1 (ceiling frames columns)))
         (cols (min columns (max 1 frames)))
         (w (+ (* cols tw) (* (1+ cols) gutter)))
         (h (+ (* rows th) (* (1+ rows) gutter))))
    (%make-sheet :pixels (make-array (* w h 3) :element-type '(unsigned-byte 8)
                                               :initial-element 16)
                 :width w :height h :tile-w tw :tile-h th
                 :columns cols :gutter gutter :scale scale :n 0)))

(defun sheet-add! (s frame frame-w frame-h)
  "Average FRAME down into the next free tile of S.

FRAME is bottom-up, as GL delivers it; the sheet is stored top-down, so
the row index is flipped here and the sheet is written with :FLIP NIL.
Doing it at this end rather than at the end costs one subtraction per
row and saves flipping an image that is much larger than any frame."
  (declare (type sheet s)
           (type (simple-array (unsigned-byte 8) (*)) frame)
           (type fixnum frame-w frame-h))
  (let* ((i (sheet-n s))
         (col (mod i (sheet-columns s)))
         (row (floor i (sheet-columns s)))
         (g (sheet-gutter s))
         (tw (sheet-tile-w s))
         (th (sheet-tile-h s))
         (sc (sheet-scale s))
         (x0 (+ g (* col (+ tw g))))
         (y0 (+ g (* row (+ th g))))
         (sw (sheet-width s))
         (px (sheet-pixels s))
         (area (* sc sc)))
    (declare (type fixnum col row g tw th sc x0 y0 sw area))
    (when (> (* (1+ row) (+ th g)) (sheet-height s))
      ;; More frames than the sheet was sized for.  Refusing is right:
      ;; the alternative is a sheet that silently drops the end of the
      ;; run, which is the half a reader would most want.
      (error "contact sheet is full at ~d frames" i))
    (dotimes (ty th)
      (dotimes (tx tw)
        (let ((r 0) (g* 0) (b 0))
          (declare (type fixnum r g* b))
          (dotimes (sy sc)
            (dotimes (sx sc)
              (let* ((fx (+ (* tx sc) sx))
                     (fy (+ (* ty sc) sy))
                     ;; frame is bottom-up: tile row 0 is the *top* of
                     ;; the picture, which is the last row of the buffer
                     (src (* 3 (+ fx (* (- frame-h 1 fy) frame-w)))))
                (declare (type fixnum fx fy src))
                (when (and (< fx frame-w) (< fy frame-h))
                  (incf r (aref frame src))
                  (incf g* (aref frame (+ src 1)))
                  (incf b (aref frame (+ src 2)))))))
          (let ((dst (* 3 (+ (+ x0 tx) (* (+ y0 ty) sw)))))
            (declare (type fixnum dst))
            (setf (aref px dst) (floor r area)
                  (aref px (+ dst 1)) (floor g* area)
                  (aref px (+ dst 2)) (floor b area))))))
    (incf (sheet-n s))
    s))

(defun write-sheet (s path)
  "Write the sheet to PATH.  :FLIP NIL — SHEET-ADD! already stored it
top-down (see there)."
  (write-png path (sheet-pixels s) (sheet-width s) (sheet-height s)
             :channels 3 :flip nil))

;;; --------------------------------------------------------------------
;;; The run
;;; --------------------------------------------------------------------

(defun timelapse-caption (h w vw vh &key (scale 2.0f0))
  "Burn the simulated time into the frame.

The whole point of a time-lapse is *when*, and a frame that does not say
when it is taken has thrown that away — which matters most on the contact
sheet, where the tiles are small and the interval is the only thing a
reader has to go on.

SCALE is why this takes an argument at all.  A caption sized for the
frame is unreadable on a tile, because the tile is the frame divided by
SHEET-SCALE and the text goes down with it; so the caller that is
building a sheet asks for text that many times larger, and the caption
comes out the same size on the tile as it would have been on the frame.
Sized after the downscale, not before it."
  (hud-reset h)
  (let* ((label (if (>= (world-seconds w) 60.0f0)
                    (format nil "~,1F MIN" (/ (world-seconds w) 60.0f0))
                    (format nil "~,1F S" (world-seconds w))))
         ;; The font is fixed-width 3x5 with a pixel of tracking, so a
         ;; plate wide enough for the label is arithmetic rather than a
         ;; guess — the same reasoning as *LIVE-KEYS* sizing its own panel.
         (adv (* 4.0f0 scale))
         (pad (* 3.0f0 scale))
         (pw (+ (* adv (length label)) (* 2.0f0 pad)))
         (ph (+ (* 5.0f0 scale) (* 2.0f0 pad))))
    ;; A plate behind it, because the ground is dark and the trail is not:
    ;; a caption legible at five seconds must still be legible at twenty
    ;; minutes with a bright road under it.
    (hud-quad h 0.0f0 (- (float vh 1.0f0) ph) pw ph
              0.02f0 0.024f0 0.03f0 0.78f0)
    (hud-text h pad (- (float vh 1.0f0) ph (- pad)) label
              :scale scale :r 0.82f0 :g 0.86f0 :b 0.92f0))
  (hud-draw h vw vh))

(defun render-timelapse (w &key (every 10.0f0) (minutes 30.0f0)
                                (width 640) (height 448)
                                view (colony 0)
                                (directory *timelapse-directory*)
                                (prefix "frame")
                                (frames t)
                                (sheet nil)
                                (sheet-columns 6)
                                (sheet-scale 4)
                                (caption t)
                                (quiet nil))
  "Run W for MINUTES simulated minutes, capturing a frame every EVERY
simulated seconds.  Returns the number of frames taken.

EVERY is in *simulated* seconds and never in wall-clock ones — a
headless run has no wall clock worth sampling, and the whole value of
the result is that the interval between two frames is a fixed amount of
ant-time.  The camera is fixed for the same reason: a frame is
comparable to the frame before it only if nothing but the world moved,
so VIEW is computed once, before the first tick, and never refitted.

FRAMES nil skips writing the individual PNGs, which is what you want when
the contact sheet is the artefact — the run still costs the same, but
nothing lands in out/.

SHEET, a pathname, also composes every frame into one image (see the
file header).  Deterministic like the gallery: same world, same seed,
same frames, byte for byte."
  (declare (type world w))
  (let* ((interval (max 1 (round (/ every *motion-dt*))))
         (total (max 1 (round (* minutes 60.0f0) (float every 1.0f0))))
         (n (1+ total))                 ; the frame at t=0 counts
         (dir (and frames (ensure-directories-exist directory)))
         (f (colony-field (nth colony (world-colonies w))))
         (sh (when sheet
               (make-sheet n width height :columns sheet-columns
                                          :scale sheet-scale))))
    (with-headless-gl (ctx :width width :height height)
      (let ((r (make-renderer :field-width (field-w f)
                              :field-height (field-h f)
                              :body-capacity (max 64 (bodies-capacity
                                                      (world-bodies w)))))
            (hud (and caption (make-hud)))
            ;; The camera is fitted to the world *once*.  A view refitted
            ;; per frame would zoom as the colony spread and the sequence
            ;; would show the camera moving rather than the ants.
            (v (or view (view-fit w :vw width :vh height))))
        (unwind-protect
             (with-offscreen (o width height)
               (dotimes (i n)
                 (when (plusp i) (world-run! w interval))
                 (bind-offscreen o)
                 (gl:clear-color 0.02 0.022 0.025 1.0)
                 (gl:clear :color-buffer-bit :depth-buffer-bit)
                 (draw-world r w v :colony colony)
                 (when hud
                   (timelapse-caption hud w width height
                                      :scale (* 2.0f0 (if sh
                                                          (float sheet-scale 1.0f0)
                                                          1.0f0))))
                 (gl:finish)
                 (let ((px (read-offscreen o)))
                   (when sh (sheet-add! sh px width height))
                   (when dir
                     (write-png (merge-pathnames
                                 (format nil "~a-~4,'0D.png" prefix i) dir)
                                px width height :channels 3 :flip t)))
                 (unless quiet
                   (format t "~&  ~4,'0D  t ~,1f s  ~d ants  trail ~,0f~%"
                           i (world-seconds w)
                           (reduce #'+ (world-colonies w)
                                   :key #'colony-population)
                           (field-total (colony-field
                                         (nth colony (world-colonies w))))))))
          (when hud (destroy-hud hud))
          (destroy-renderer r))
        (when sh
          (write-sheet sh sheet)
          (unless quiet
            (format t "~&  ~a  (~dx~d, ~d frames)~%"
                    (namestring sheet) (sheet-width sh) (sheet-height sh)
                    (sheet-n sh))))
        n))))

(defun render-timelapse-demo (&key (minutes 30.0f0) (every 20.0f0)
                                   (sheet #p"docs/images/16-timelapse.png")
                                   (columns 8) (scale 5)
                                   (frames nil) (seed +default-seed+))
  "The shipped time-lapse: half an hour of the gallery's own scenario,
sampled every ten simulated seconds, as one contact sheet.

The *gallery's* world and not a new one, deliberately.  The stills in
docs/DIARY.md are moments from this run; a sheet built from a different
world would show a different colony and quietly invite the reader to
compare two things that are not comparable.  Same constructor, same
seed, same `*RESTING-ANTS-BLOCK*` as RENDER-GALLERY — so tile 30 of the
sheet and `03-trail.png` are the same twenty minutes.

Half an hour because that is the span over which this scenario has a
story: a trail forms inside five minutes, thickens, and the source is
visibly down by thirty.  Twenty seconds because the trail goes from
nothing to a road between 40 s and 100 s — at a one-minute interval that
whole event falls between two tiles, and at five the sheet is a wall of
pictures that differ by nothing.

The result is 91 tiles in 8 columns, which is a page rather than a
strip: a reader compares a tile with the one above it as readily as with
the one beside it, and the run's shape is visible without scrolling."
  (let ((w (gallery-world :seed seed)))
    (format t "~&time-lapse: ~,1f min every ~,1f s~%" minutes every)
    (let ((*resting-ants-block* t))
      (render-timelapse w :minutes minutes :every every
                          :frames frames :sheet sheet
                          :sheet-columns columns :sheet-scale scale))))
