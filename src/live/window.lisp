;;;; live/window.lisp — the interactive window (§5.5).
;;;;
;;;; A second *consumer* of the frame, never a fork of it.  This file
;;;; creates a window, pumps events and drives the clock; every pixel is
;;;; drawn by the same DRAW-WORLD the headless tests use, into framebuffer
;;;; 0 instead of an FBO.  That is what keeps the watched path and the
;;;; tested path the same path.
;;;;
;;;; Note this context comes from GLFW, not from EGL — the headless path
;;;; in render/egl.lisp is not involved.  The libGL preload still is, and
;;;; still matters: it is what makes the window's GL and the process's GL
;;;; the same implementation (§5.4).

(in-package #:antsim)

;;; A single window is the whole design, so its state is global rather
;;; than threaded through callbacks that GLFW will only ever call with
;;; the arguments it chooses.
(defvar *live-world* nil)
(defvar *live-view* nil)
(defvar *live-renderer* nil)
(defvar *live-paused* nil)
(defvar *live-speed* 1.0f0
  "Time compression: simulated seconds per real second.  §4.3 wants 1x,
100x and as-fast-as-possible from the same code, so this is a multiplier
on the clock rather than a different loop.")
(defvar *live-dragging* nil)
(defvar *live-last-x* 0.0f0)
(defvar *live-last-y* 0.0f0)

(defun live-faster ()
  (setf *live-speed* (min 4096.0f0 (* *live-speed* 2.0f0)))
  (format t "~&speed ~,1fx~%" *live-speed*))

(defun live-slower ()
  (setf *live-speed* (max 0.03125f0 (/ *live-speed* 2.0f0)))
  (format t "~&speed ~,1fx~%" *live-speed*))

;;; Time compression is read from the *character* rather than the key.
;;;
;;; GLFW reports keys by their physical position on a US layout, not by
;;; the symbol printed on the cap.  On a German QWERTZ the `+` key sits
;;; where US has `]`, so it arrives as :RIGHT-BRACKET and a handler
;;; written for :EQUAL never fires — which is exactly what happened here.
;;; The character callback is layout-aware by definition and needs no
;;; table of national layouts, so `+` and `-` come from it, while the key
;;; callback keeps only the keys whose position *is* their meaning (space,
;;; home, escape) plus the keypad, which is unambiguous everywhere.
;;;
;;; DEF-CHAR-CALLBACK takes no docstring: a string here would stop being
;;; documentation and start being the body's first form, which pushes the
;;; DECLARE out of head position.
(glfw:def-char-callback live-char (window codepoint)
  (declare (ignore window))
  ;; cl-glfw3 hands this callback a CHARACTER, despite the GLFW C API
  ;; passing a Unicode code point.  Accept either rather than depend on
  ;; which — CODE-CHAR of a character is a type error, and it happens in
  ;; a callback, where the backtrace points at the event pump rather than
  ;; at this line.
  (let ((ch (if (characterp codepoint) codepoint (code-char codepoint))))
    (case ch
      ((#\+ #\=) (live-faster))
      ((#\- #\_) (live-slower))
      (t nil))))

(glfw:def-key-callback live-key (window key scancode action mods)
  (declare (ignore window scancode mods))
  (when (or (eq action :press) (eq action :repeat))
    (case key
      (:escape (glfw:set-window-should-close))
      (:space (setf *live-paused* (not *live-paused*))
              (format t "~&~:[running~;paused~]~%" *live-paused*))
      ;; Only the *keypad* +/- are handled here.  The main-row ones come
      ;; through LIVE-CHAR instead — see the note there.
      (:kp-add (live-faster))
      (:kp-subtract (live-slower))
      (:home (when (and *live-world* *live-view*)
               (let ((v (view-fit *live-world*
                                  :vw (view-vw *live-view*)
                                  :vh (view-vh *live-view*))))
                 (setf (view-cx *live-view*) (view-cx v)
                       (view-cy *live-view*) (view-cy v)
                       (view-span *live-view*) (view-span v)))))
      (t nil))))

(glfw:def-scroll-callback live-scroll (window x y)
  (declare (ignore window x))
  (when *live-view*
    (destructuring-bind (cx cy) (glfw:get-cursor-position)
      ;; Anchored at the cursor, not the screen centre (§5.5).  All of the
      ;; arithmetic is in VIEW-ZOOM-AT!, which has its own test.
      (view-zoom-at! *live-view*
                     (float cx 1.0f0) (float cy 1.0f0)
                     (if (plusp y) 1.15f0 (/ 1.0f0 1.15f0))))))

(glfw:def-mouse-button-callback live-mouse (window button action mods)
  (declare (ignore window mods))
  (when (eq button :right)
    (setf *live-dragging* (eq action :press))
    (when *live-dragging*
      (destructuring-bind (cx cy) (glfw:get-cursor-position)
        (setf *live-last-x* (float cx 1.0f0)
              *live-last-y* (float cy 1.0f0)))))
  (when (and (eq button :left) (eq action :press) *live-world* *live-view*)
    (destructuring-bind (cx cy) (glfw:get-cursor-position)
      (live-inspect (float cx 1.0f0) (float cy 1.0f0)))))

(glfw:def-cursor-pos-callback live-cursor (window x y)
  (declare (ignore window))
  (when *live-dragging*
    (view-pan-pixels! *live-view*
                      (- (float x 1.0f0) *live-last-x*)
                      (- (float y 1.0f0) *live-last-y*)))
  (setf *live-last-x* (float x 1.0f0)
        *live-last-y* (float y 1.0f0)))

(defun live-inspect (px py)
  "Report the ant nearest the click.  §5.5 lists inspection under the
window's controls; the rich version is M5's, and this is the cheap one
that makes the state machine observable while it is being calibrated."
  (multiple-value-bind (wx wy) (view-screen->world *live-view* px py)
    (let* ((w *live-world*) (a (world-ants w)) (b (world-bodies w))
           (best nil) (best-d2 most-positive-single-float))
      (dotimes (i (ants-n a))
        (when (ant-live-p a i)
          (let* ((bi (aref (ants-body a) i))
                 (dx (- (aref (bodies-x b) bi) wx))
                 (dy (- (aref (bodies-y b) bi) wy))
                 (d2 (+ (* dx dx) (* dy dy))))
            (when (< d2 best-d2) (setf best-d2 d2 best i)))))
      (if (and best (< best-d2 (* 0.02f0 0.02f0)))
          (format t "~&ant ~d  state ~a  energy ~,3f  crop ~,3f  age ~d  ~
                     home (~,3f ~,3f)~%"
                  (aref (ants-id a) best)
                  (case (aref (ants-state a) best)
                    (0 "in-nest") (1 "outbound") (2 "at-food")
                    (3 "returning") (t "dead"))
                  (aref (ants-energy a) best)
                  (aref (ants-crop a) best)
                  (aref (ants-age a) best)
                  (aref (ants-hvx a) best) (aref (ants-hvy a) best))
          (format t "~&(no ant near ~,3f ~,3f)~%" wx wy)))))

(defun live-title (w fps)
  (let ((c (first (world-colonies w))))
    (format nil "antsim — t ~,1f s · ~d ants · stock ~,0f · trail ~,0f · ~
                 ~,1fx~:[~; (paused)~] · ~,0f fps"
            (world-seconds w)
            (if c (colony-population c) 0)
            (if c (colony-stock c) 0.0)
            (if c (field-total (colony-field c)) 0.0d0)
            *live-speed* *live-paused* fps)))

(defun run-live (w &key (width 1100) (height 800) (title "antsim"))
  "Open a window on W and run it (§5.5).

Controls:
  wheel        zoom, anchored at the cursor
  right-drag   pan
  left-click   inspect the ant under the pointer
  space        pause
  + / -        time compression, halving and doubling
  home         frame the whole world
  escape       quit

Returns the world, so a session can keep poking at it afterwards."
  (declare (type world w))
  (glfw:with-init-window (:title title :width width :height height
                          :context-version-major 4
                          :context-version-minor 5
                          :opengl-profile :opengl-core-profile
                          :opengl-forward-compat t)
    (unless (gl:get-string :version)
      (error "GL reports no version string — the libGL trap (§5.4). ~
              Run under: guix shell glfw nvda@580 -- ..."))
    (format t "~&GL ~a | ~a~%" (gl:get-string :version) (gl:get-string :renderer))
    (glfw:set-key-callback 'live-key)
    (glfw:set-char-callback 'live-char)
    (glfw:set-scroll-callback 'live-scroll)
    (glfw:set-mouse-button-callback 'live-mouse)
    (glfw:set-cursor-position-callback 'live-cursor)
    (let* ((f (colony-field (first (world-colonies w))))
           (r (make-renderer :field-width (field-w f)
                             :field-height (field-h f)
                             :body-capacity (max 64 (bodies-capacity
                                                     (world-bodies w))))))
      (setf *live-world* w
            *live-renderer* r
            *live-view* (view-fit w :vw width :vh height)
            *live-paused* nil)
      (unwind-protect
           (let ((last (glfw:get-time))
                 (carry 0.0f0)
                 (fps 0.0f0)
                 (title-timer 0.0f0))
             (loop until (glfw:window-should-close-p)
                   do (let* ((now (glfw:get-time))
                             (dt (float (min 0.1d0 (- now last)) 1.0f0)))
                        (setf last now)
                        (when (> dt 0.0f0)
                          (setf fps (+ (* 0.9f0 fps) (* 0.1f0 (/ 1.0f0 dt)))))
                        ;; Advance the sim by wall-clock time times the
                        ;; compression, carrying the fractional remainder
                        ;; so that slow speeds do not quantise to zero and
                        ;; fast ones do not depend on the frame rate.
                        (unless *live-paused*
                          (incf carry (/ (* dt *live-speed*) *motion-dt*))
                          (let ((steps (min 20000 (floor carry))))
                            (decf carry steps)
                            (dotimes (i steps) (world-step! w))))
                        ;; the window may have been resized.  Note
                        ;; cl-glfw3 returns a *list*, not multiple values.
                        (destructuring-bind (fw fh)
                            (glfw:get-framebuffer-size)
                          (setf (view-vw *live-view*) fw
                                (view-vh *live-view*) fh)
                          (gl:bind-framebuffer :framebuffer 0)
                          (gl:viewport 0 0 fw fh))
                        (gl:clear-color 0.02 0.022 0.025 1.0)
                        (gl:clear :color-buffer-bit :depth-buffer-bit)
                        (draw-world r w *live-view*)
                        (glfw:swap-buffers)
                        (glfw:poll-events)
                        (incf title-timer dt)
                        (when (> title-timer 0.25f0)
                          (setf title-timer 0.0f0)
                          (glfw:set-window-title (live-title w fps))))))
        (destroy-renderer r)
        (setf *live-world* nil *live-renderer* nil))))
  w)

(defun live-demo (&key (width 1100) (height 800))
  "The scenario the M2 gallery renders, but watchable.  A single colony,
one food source, one obstacle — enough to see a trail form, thicken and
carry traffic."
  (let* ((w (make-world :width 0.6f0 :height 0.6f0 :capacity 4000))
         (c (add-colony w :name "home" :nest-x 0.30f0 :nest-y 0.10f0
                          :nest-r 0.02f0 :capacity 1500 :stock 400.0f0)))
    (add-food w 0.30f0 0.28f0 0.03f0 5000.0f0 :quality 1.0f0)
    (add-obstacle w '(0.10 0.16 0.22 0.16 0.22 0.19 0.10 0.19))
    (world-seed-population! w c 120)
    (run-live w :width width :height height)))
