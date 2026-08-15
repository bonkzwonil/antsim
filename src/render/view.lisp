;;;; render/view.lisp — the orthographic camera (§5.5).
;;;;
;;;; Deliberately a plain value: a centre, a horizontal span, and a
;;;; viewport.  The renderer takes one of these and does not care whether
;;;; the frame is going to an FBO or a window, which is what keeps the
;;;; tested path and the watched path the same path.
;;;;
;;;; The camera lands with the renderer rather than at the end because
;;;; without pan and zoom the arena size, the ant count and the render
;;;; scale are locked together and all three have to be guessed correctly
;;;; up front.  With them, one run is legible at any scale.

(in-package #:antsim)

(defstruct (view (:constructor %make-view))
  (cx 0.5f0 :type f32)                  ; centre, world metres
  (cy 0.5f0 :type f32)
  (span 1.0f0 :type f32)                ; world metres across the viewport
  (vw 960 :type fixnum)                 ; viewport, pixels
  (vh 600 :type fixnum))

(defun make-view (&key (cx 0.5f0) (cy 0.5f0) (span 1.0f0) (vw 960) (vh 600))
  (%make-view :cx (float cx 1.0f0) :cy (float cy 1.0f0)
              :span (float span 1.0f0) :vw vw :vh vh))

(defun view-fit (w &key (vw 960) (vh 600) (margin 1.04f0))
  "A view framing the whole world, with a little air around it.  This is
what the `home` key restores (§5.5)."
  (declare (type world w))
  (let* ((aspect (/ (float vw 1.0f0) (float vh 1.0f0)))
         ;; fit whichever dimension is tighter
         (span (max (* (world-width w) margin)
                    (* (world-height w) margin aspect))))
    (make-view :cx (* 0.5f0 (world-width w)) :cy (* 0.5f0 (world-height w))
               :span span :vw vw :vh vh)))

(declaim (inline view-span-y))
(defun view-span-y (v)
  "Vertical extent in world metres.  Derived from the horizontal span and
the viewport aspect, never stored — storing both is how a camera ends up
able to represent a non-square pixel."
  (declare (type view v))
  (* (view-span v) (/ (float (view-vh v) 1.0f0) (float (view-vw v) 1.0f0))))

(defun view-world->screen (v x y)
  "World metres to pixels, origin top-left as a window reports a cursor."
  (declare (type view v) (type f32 x y))
  (let* ((sx (/ (float (view-vw v) 1.0f0) (view-span v)))
         (sy (/ (float (view-vh v) 1.0f0) (view-span-y v))))
    (values (* (+ (- x (view-cx v)) (* 0.5f0 (view-span v))) sx)
            ;; y flips: world y is up, screen y is down
            (* (- (* 0.5f0 (view-span-y v)) (- y (view-cy v))) sy))))

(defun view-screen->world (v px py)
  "Pixels to world metres.  The inverse of VIEW-WORLD->SCREEN, and the
function cursor-anchored zoom is built out of."
  (declare (type view v) (type f32 px py))
  (let ((sx (/ (view-span v) (float (view-vw v) 1.0f0)))
        (sy (/ (view-span-y v) (float (view-vh v) 1.0f0))))
    (values (+ (view-cx v) (- (* px sx) (* 0.5f0 (view-span v))))
            (+ (view-cy v) (- (* 0.5f0 (view-span-y v)) (* py sy))))))

(defun view-zoom-at! (v px py factor)
  "Zoom by FACTOR about the cursor at pixel (PX, PY): the world point
under the pointer stays under it.

§5.5 calls this out because the obvious implementation — scale about the
screen centre — feels wrong the instant anyone uses it, and doing it
properly is the same two lines of arithmetic.  Take the world point under
the cursor, change the span, then move the centre so that point maps back
to the same pixel."
  (declare (type view v) (type f32 px py factor))
  (multiple-value-bind (wx wy) (view-screen->world v px py)
    (setf (view-span v) (max 1.0f-3 (/ (view-span v) factor)))
    (multiple-value-bind (nx ny) (view-screen->world v px py)
      (incf (view-cx v) (- wx nx))
      (incf (view-cy v) (- wy ny))))
  v)

(defun view-pan-pixels! (v dpx dpy)
  "Drag the world by a pixel delta — right-drag (§5.5)."
  (declare (type view v) (type f32 dpx dpy))
  (let ((sx (/ (view-span v) (float (view-vw v) 1.0f0)))
        (sy (/ (view-span-y v) (float (view-vh v) 1.0f0))))
    (decf (view-cx v) (* dpx sx))
    (incf (view-cy v) (* dpy sy)))      ; screen y is down, world y is up
  v)

(defun view-bounds (v)
  "Values: x0, y0, x1, y1 — the world rectangle currently visible."
  (declare (type view v))
  (let ((hx (* 0.5f0 (view-span v)))
        (hy (* 0.5f0 (view-span-y v))))
    (values (- (view-cx v) hx) (- (view-cy v) hy)
            (+ (view-cx v) hx) (+ (view-cy v) hy))))
