;;;; tui/live.lisp — watching a colony in a terminal (§5.6).
;;;;
;;;; The loop, and the keys.  It is the window's loop with the GL taken
;;;; out and nothing else changed in principle: read what the user did,
;;;; advance the simulation by wall-clock time rather than by frames,
;;;; draw, show it.
;;;;
;;;; The simulation itself is untouched.  This calls WORLD-STEP! and reads
;;;; exported accessors, exactly as the window does — the terminal view
;;;; and the window view are two readings of one world, never two worlds.
;;;; Nothing here holds simulation state the window cannot see, and
;;;; nothing here steps the world in a way the window does not.

(in-package #:antsim)

(defparameter *tui-speed* 4.0f0
  "Simulated seconds per real second.  Four, matching the window's
*LIVE-SPEED*: at 1x a trail takes long enough to form that the first
thing a new watcher concludes is that nothing is happening.")

(defparameter *tui-paused* nil)

(defparameter *tui-target-fps* 30.0f0
  "Frames per second to aim for.  The simulation rate is independent of
this — see the accumulator below — so this is purely how often the
picture is refreshed, and thirty is far past what a grid of characters
needs to look smooth.")

(defun tui-fresh-seed ()
  "A seed nobody chose, for a session nobody intends to reproduce.  The
same argument FRESH-SEED makes in the window: the ban in §4.4 is on the
*simulation* having a hidden source of randomness, not on a human picking
a number before the world exists."
  (logand #xFFFFFFFF
          (hash32 (logand #xFFFFFFFF
                          (logxor (get-universal-time)
                                  (get-internal-real-time))))))

(defun tui-seed (seed)
  (if seed (logand #xFFFFFFFF seed) (tui-fresh-seed)))

;;; --- the loop ----------------------------------------------------------

(defstruct (tui-session (:conc-name tses-))
  (cols 80 :type fixnum)
  (rows 24 :type fixnum)
  (camera nil)
  (front nil)                           ; what is on screen
  (back nil)                            ; what is being drawn
  (colony 0 :type fixnum)
  (charset :unicode)
  (colour t)
  (help nil)
  (fps 0.0f0 :type f32)
  (quit nil)
  (step-once nil))

(defun tui-resize! (s w)
  "Take the terminal's current size and rebuild everything that depended
on the old one.

The camera keeps its centre and its scale — the world the user was
looking at is still the world they are looking at — and simply shows more
or less of it.  Re-fitting instead would throw away their zoom every time
the window manager twitched.

The front canvas is dropped rather than resized, which forces a full
repaint: after a size change nothing is where it was, so a diff against
the old screen is not merely useless but wrong."
  (multiple-value-bind (rows cols) (tui-terminal-size)
    (let ((rows (max 1 (or rows 24)))
          (cols (max 1 (or cols 80))))
      (setf (tses-rows s) rows
            (tses-cols s) cols
            (tses-back s) (make-tui-canvas cols rows)
            (tses-front s) nil)
      (if (tses-camera s)
          (tui-clamp! (tses-camera s) w cols (max 1 (1- rows)))
          (setf (tses-camera s) (tui-fit w cols (max 1 (1- rows)))))))
  s)

(defun tui-handle-key (s key w)
  "Act on one key.  Returns nothing; everything it does is to the session."
  (let* ((cols (tses-cols s))
         (rows (max 1 (1- (tses-rows s))))
         (page-x (max 1 (floor cols 2)))
         (page-y (max 1 (floor rows 2)))
         (cam (tses-camera s)))
    (flet ((pan (dc dr) (tui-pan! cam w cols rows dc dr))
           (zoom (f) (tui-zoom! cam w cols rows f)))
      (case key
        ((:left)  (pan -1 0))
        ((:right) (pan 1 0))
        ((:up)    (pan 0 -1))
        ((:down)  (pan 0 1))
        ((:shift-left  :page-left)  (pan (- page-x) 0))
        ((:shift-right :page-right) (pan page-x 0))
        ((:shift-up   :page-up)     (pan 0 (- page-y)))
        ((:shift-down :page-down)   (pan 0 page-y))
        ((:home) (setf (tses-camera s) (tui-fit w cols rows)))
        (t
         (when (characterp key)
           (case key
             ;; vi keys, because a terminal is where the fingers already
             ;; are.  Capitals move a page, which is the convention every
             ;; pager in the world uses.
             (#\h (pan -1 0)) (#\l (pan 1 0))
             (#\k (pan 0 -1)) (#\j (pan 0 1))
             (#\H (pan (- page-x) 0)) (#\L (pan page-x 0))
             (#\K (pan 0 (- page-y))) (#\J (pan 0 page-y))
             ;; Speed, pause and quit keep the window's bindings.  Two
             ;; views that disagree about what the space bar does are two
             ;; things to remember instead of one.
             ((#\+ #\=) (setf *tui-speed* (min 4096.0f0 (* 2.0f0 *tui-speed*))))
             ((#\- #\_) (setf *tui-speed* (max 0.03125f0 (/ *tui-speed* 2.0f0))))
             (#\Space (setf *tui-paused* (not *tui-paused*)))
             ;; The window has no single-step; a terminal is exactly
             ;; where one is wanted, because it is the only place you can
             ;; watch a tick at a time without a debugger.
             (#\. (setf (tses-step-once s) t *tui-paused* t))
             (#\f (setf (tses-camera s) (tui-fit w cols rows)))
             (#\z (zoom 1.3f0))
             (#\Z (zoom (/ 1.0f0 1.3f0)))
             (#\t (let ((n (length (world-colonies w))))
                    (when (plusp n)
                      (setf (tses-colony s) (mod (1+ (tses-colony s)) n)))))
             (#\a (setf (tses-charset s)
                        (if (eq (tses-charset s) :ascii) :unicode :ascii)))
             (#\c (setf (tses-colour s) (not (tses-colour s))))
             ((#\? #\/) (setf (tses-help s) (not (tses-help s))))
             ((#\q #\Q) (setf (tses-quit s) :quit)))))))
    (case key
      ((:escape) (setf (tses-quit s) :quit))
      ((:ctrl-c) (setf (tses-quit s) :interrupt)))))

(defun tui-draw-help! (cv)
  "The key legend, over whatever is under it.

A panel rather than a permanent strip: the legend is read once and then
is in the way, and screen in a terminal is the scarcest thing there is."
  (let* ((lines (tui-help-lines))
         (w (+ 2 (reduce #'max lines :key #'length)))
         (h (+ 2 (length lines)))
         (col (max 0 (floor (- (tcv-cols cv) w) 2)))
         (row (max 0 (floor (- (tcv-rows cv) h) 2))))
    (dotimes (r h)
      (dotimes (c w)
        (tui-put! cv (+ col c) (+ row r) #\Space +tui-default+)))
    (loop for line in lines
          for r from 1
          do (tui-write! cv (+ col 1) (+ row r) line +tui-white+))
    cv))

(defun run-tui (w &key (colony 0) (charset :unicode) (colour t) seed)
  "Watch W in the terminal.  Returns a process exit code.

SEED is not used to build the world — by the time a world is here its
seed is fixed — and is accepted only so the caller can print it."
  (declare (type world w) (ignore seed))
  (unless (tui-tty-p)
    ;; Named, with the next step, per the rule the rest of the program's
    ;; output follows: a message that says only "not a terminal" leaves
    ;; the reader to guess whether that is their fault.
    ;;
    ;; The name is written out rather than taken from *PROGRAM-NAME*, and
    ;; that is the dependency rule rather than an oversight: that
    ;; variable belongs to app/main, this system sits below it, and
    ;; nothing down here may know that a *program* exists.  Reaching up
    ;; for it would put antsim/app under antsim/tui and take away the one
    ;; property this system is for — loading on a machine with no
    ;; graphics stack.
    (format *error-output*
            "~&antsim: standard output is not a terminal, so there is nothing ~
             to draw on.~%Run it from a terminal, or use the window instead.~%")
    (return-from run-tui 2))
  (let ((s (make-tui-session :colony colony :charset charset :colour colour))
        (pending "")
        (carry 0.0d0)
        (last (/ (float (get-internal-real-time) 1.0d0)
                 internal-time-units-per-second)))
    (with-terminal ()
      (tui-resize! s w)
      (loop until (tses-quit s)
            do (let* ((now (/ (float (get-internal-real-time) 1.0d0)
                              internal-time-units-per-second))
                      ;; Clamped, exactly as the window clamps it: a frame
                      ;; that took a second — the process was stopped, the
                      ;; laptop was shut — must not be paid back as a
                      ;; thousand ticks of catch-up in one go.
                      (dt (min 0.1d0 (max 0.0d0 (- now last)))))
                 (setf last now)
                 (setf (tses-fps s)
                       (+ (* 0.9f0 (tses-fps s))
                          (* 0.1f0 (if (plusp dt) (/ 1.0f0 (float dt 1.0f0)) 0.0f0))))
                 ;; --- what the user did ---------------------------------
                 (let ((got (tui-read-available)))
                   (setf pending (concatenate 'string pending got))
                   (multiple-value-bind (keys rest)
                       ;; FLUSH when this poll brought nothing: a lone ESC
                       ;; that is still alone after a whole frame is the
                       ;; escape key and not the head of an arrow.
                       (tui-decode-keys pending :flush (zerop (length got)))
                     (setf pending rest)
                     (dolist (k keys) (tui-handle-key s k w))))
                 ;; --- the terminal changed shape ------------------------
                 (when *tui-resized*
                   (setf *tui-resized* nil)
                   (tui-resize! s w))
                 ;; --- the simulation ------------------------------------
                 ;; A fractional accumulator, not a fixed number of ticks
                 ;; per frame: the tick is 50 ms and the frame is 33, so
                 ;; anything that rounds drifts, and slow speeds would
                 ;; quantise to no ticks at all.
                 (cond
                   ((tses-step-once s)
                    (setf (tses-step-once s) nil)
                    (world-step! w))
                   ((not *tui-paused*)
                    (incf carry (/ (* dt *tui-speed*) *motion-dt*))
                    (let ((steps (min 20000 (floor carry))))
                      (decf carry steps)
                      (dotimes (i steps) (world-step! w)))))
                 ;; --- draw ----------------------------------------------
                 (let ((back (tses-back s)))
                   (tui-clear! back)
                   (tui-write! back 0 0
                               (tui-status w :colony (tses-colony s)
                                             :speed *tui-speed*
                                             :paused *tui-paused*
                                             :fps (tses-fps s)
                                             :cols (tses-cols s))
                               (if (tses-colour s) +tui-white+ +tui-default+))
                   (tui-draw-world! back w (tses-camera s)
                                    :top 1
                                    :colony (tses-colony s)
                                    :charset (tses-charset s)
                                    :colour (tses-colour s))
                   (when (tses-help s) (tui-draw-help! back))
                   (tui-emit-diff *standard-output*
                                  (tui-canvas-diff (tses-front s) back))
                   (force-output *standard-output*)
                   (setf (tses-front s) (tui-canvas-copy! (tses-front s) back)))
                 ;; --- and wait ------------------------------------------
                 (let ((spent (- (/ (float (get-internal-real-time) 1.0d0)
                                    internal-time-units-per-second)
                                 now)))
                   (sleep (max 0.0d0 (- (/ 1.0d0 *tui-target-fps*) spent)))))))
    ;; 130 for an interrupt, matching the shell's convention and the
    ;; window's: quitting a view you are watching is not a crash.
    (if (eq (tses-quit s) :interrupt) 130 0)))

;;; --- ways in -----------------------------------------------------------

(defun tui-demo (&key seed (colony 0) (charset :unicode) (colour t))
  "The world the M2 gallery renders, in a terminal.  One colony, one food
source, one obstacle — enough to watch a trail form and thicken."
  (let* ((sd (tui-seed seed))
         (w (make-world :width 0.6f0 :height 0.6f0 :capacity 8000 :seed sd))
         (c (add-colony w :name "home" :nest-x 0.30f0 :nest-y 0.08f0
                          :nest-r 0.02f0 :capacity 3000 :stock 500.0f0)))
    (add-food w 0.34f0 0.43f0 0.03f0 2500.0f0 :quality 1.0f0)
    (add-obstacle w '(0.12 0.20 0.30 0.20 0.30 0.235 0.12 0.235))
    (world-seed-population! w c 150)
    (format t "~&seed ~d   (repeat this run with --seed ~d)~%" sd sd)
    (finish-output)
    (run-tui w :colony colony :charset charset :colour colour)))

(defun tui-scenario (path &key seed (colony 0) (charset :unicode) (colour t))
  "Watch a scenario file (§6) in a terminal.

The scenario's parameter overrides are bound around the whole run and not
merely around loading it — a file that sets tau and then runs under the
default tau would be a particularly quiet lie."
  (let* ((s (load-scenario path :seed (tui-seed seed)))
         (w (scenario-world s)))
    (format t "~&~a: ~,2f x ~,2f m, ~d colon~:@p, ~d source~:p~@[, ~a~]~%~
                 seed ~d   (repeat this run with --seed ~d)~%"
            (scenario-name s) (world-width w) (world-height w)
            (length (scenario-colonies s)) (length (scenario-foods s))
            (scenario-species s) (world-seed w) (world-seed w))
    (finish-output)
    (with-scenario-params (s)
      (run-tui w :colony colony :charset charset :colour colour))))
