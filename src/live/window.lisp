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
(defvar *live-speed* 4.0f0
  "Time compression: simulated seconds per real second.  §4.3 wants 1x,
100x and as-fast-as-possible from the same code, so this is a multiplier
on the clock rather than a different loop.

Opens at 4x rather than 1x.  Real time is the wrong default for watching
this: the interesting quantities — a trail forming, a source running
down, a colony growing — move on scales of minutes to an hour, and at 1x
the first thing a new watcher sees is several minutes of ants wandering
in silence.  The clock is still exact at any multiplier; only the
starting point moved.")

(defvar *live-colony* 0
  "Which colony the HUD reports and whose trail field is drawn.

One field is on screen at a time, and that is a decision rather than a
limitation: two pheromone fields composited together would show a
*mixture* nobody in the world can smell.  Each colony reads its own field
and only eavesdrops on the others through ε (§3.12), so the honest
picture is one colony's world at a time, switched with a key.

The ants themselves are always all drawn, and always in their own tribe's
colours — who is on screen is not the question, whose *chemistry* is.")

(defvar *live-keyhelp* t
  "Whether the key legend is drawn.  On by default: the controls are not
guessable, and a window that does not say what it responds to is a window
most people will only pan around in.")
(defvar *live-hud* nil)

(defvar *live-species* nil
  "The species the running scenario named, or NIL if it named none.

Display only.  What the species *does* is bind parameters, and that has
already happened by the time anything here reads this — so this is a
label, and it exists because a parameter set is invisible: two runs of
the same arena that behave nothing alike look, to a watcher, like a bug
in one of them.")

(defparameter *live-food-amount* 200.0f0
  "How much food the A key drops (§5.5).

200 rather than the 2500 a scenario source carries, because the point of
dropping one by hand is to watch a colony *find* it and strip it inside a
minute or two — a source that outlives your attention teaches nothing
that the scenario file does not already show.  Small enough to vanish,
large enough that the trail to it has time to form.")

(defparameter *live-food-radius* 0.015f0
  "The radius of a dropped source at its starting amount, metres.

Fixes the density, and the density is what makes the drawn disc mean
something absolute: the source shrinks as it is eaten, so the circle is
the food rather than a fraction of what it started as (§5.1).  Also the
collision radius — a smaller pile has a shorter edge, so fewer ants can
reach it at once, which is the queueing at a dwindling source you can
watch happen.")
(defparameter *live-block-half* 0.010f0
  "Half the side of the square the O key drops, metres.

So a 2 cm block, which is not an arbitrary size: the walls the scenarios
author are 1.6 cm thick (`two-tribes`), and terrain placed by hand should
be the same order as terrain placed by the file or the two do not compare.
Four ant body lengths, so it is an obstruction rather than a pebble, and
small enough that a wall is something you draw rather than something you
stamp once.")

(defparameter *live-block-limit* 200
  "How many blocks may be dropped by hand into one world.

There is a limit because O repeats while it is held, and because terrain
is the one thing in the world with no spatial index: BODIES-RESOLVE!
tests every body against every polygon, every iteration, every tick.
That is a bounding-box rejection and it is cheap — 200 blocks against
4000 bodies is a few percent of one core — but it is linear in a number a
key repeat can drive to thousands, and a window that quietly slows to a
crawl the longer you hold a key is worse than one that says it has had
enough.  Scenario obstacles are not counted: those are the author's
business, and no author has written 200.")

(defvar *live-blocks* 0
  "Blocks dropped by hand so far, against *LIVE-BLOCK-LIMIT*.")

(defparameter *live-poke-slack* 0.020f0
  "How far outside a nest disc a poke still counts, metres (§5.5).

A nest entrance is 2 cm across and the view is usually zoomed out far
enough that 2 cm is a few pixels.  Requiring the click to land inside it
would make the one interaction §3.3 names hardest to reach, so the target
is the entrance plus its own radius again.  Generous, and safe: the only
thing there is to hit by accident is a nest, and poking one is
reversible in the strongest sense — the colony calms down on its own.")

(defvar *live-note* nil
  "The last line the window printed about an action, or NIL.  Held so a
key that repeats while it is held does not repeat itself thirty times a
second — see LIVE-NOTE.")

(defun live-note (control &rest args)
  "Say what a key just did, but only when it is not what was said last.

O and P both repeat while they are held — that is what makes a wall
something you draw and a nest something you keep prodding — so a line
printed on every call would bury the terminal in copies of one sentence.
Silence is the right report for \"that worked again\"."
  (let ((s (and control (apply #'format nil control args))))
    (unless (equal s *live-note*)
      (setf *live-note* s)
      (when s (format t "~&~a~%" s)))))

(defvar *live-selected* nil
  "Slot of the inspected ant, or NIL.  Held with its id so the panel can
tell 'the ant you clicked' from 'whatever now occupies that slot' — slots
are recycled by the free list, and an ant dying under the cursor would
otherwise silently swap the readout for a different individual.")
(defvar *live-selected-id* 0)
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
      ;; q quits, which is the Unix convention and worth honouring even
      ;; though escape already does.  It is layout-independent for free
      ;; here, because this callback reports characters rather than key
      ;; positions.
      ((#\q #\Q) (glfw:set-window-should-close))
      ((#\h #\H #\?) (setf *live-keyhelp* (not *live-keyhelp*)))
      ;; Toggle whether ants resting in the nest take part in ant-ant
      ;; collision (§3.11).  Live rather than at startup because the
      ;; question it settles is a visual one: the change is defensible on
      ;; modelling grounds — the nest disc is a door, and the real thing
      ;; is a chamber system going down — and it costs about 14% of the
      ;; food delivered for reasons no measurement has explained.  An
      ;; unexplained cost of that size is as likely to be a bug as a
      ;; trade-off, and the cheapest way to find out is to watch one
      ;; colony both ways.
      ((#\a #\A)
       (destructuring-bind (cx cy) (glfw:get-cursor-position)
         (live-drop-food (float cx 1.0f0) (float cy 1.0f0))))
      ;; Terrain, by hand, into a world that is already running.  Held
      ;; down rather than pressed once: GLFW repeats the character
      ;; callback, so O plus a moving cursor paints a wall out of blocks,
      ;; and a wall is the shape of the only question worth asking here —
      ;; whether a colony that has committed to a road can find another
      ;; one once that road is cut.
      ((#\o #\O)
       (destructuring-bind (cx cy) (glfw:get-cursor-position)
         (live-drop-block (float cx 1.0f0) (float cy 1.0f0))))
      ;; Poke the nest, and watch it erupt (§3.3).  The one thing in this
      ;; model that releases alarm — see LIVE-POKE-NEST.
      ((#\p #\P)
       (destructuring-bind (cx cy) (glfw:get-cursor-position)
         (live-poke-nest (float cx 1.0f0) (float cy 1.0f0))))
      ((#\n #\N)
       (setf *resting-ants-block* (not *resting-ants-block*))
       (format t "~&resting ants ~:[pass through each other~;collide~]~%"
               *resting-ants-block*))
      ;; The crowd, on a key (§3.11, *ant-collision*).  Terrain, food and
      ;; corpses keep blocking, so the arena is unchanged and the only
      ;; thing that disappears is ant-ant contact — which makes it a
      ;; direct way to see how much of a jam is navigation and how much
      ;; is the solver.  Toggling it live matters more than the number:
      ;; a pocket that empties the instant ants stop touching is a
      ;; different diagnosis from one that does not.
      ((#\c #\C)
       (setf *ant-collision* (not *ant-collision*))
       (format t "~&ant-ant contact ~:[OFF — ants pass through each other~;on~]~%"
               *ant-collision*))
      ;; Step the focus to the next colony.  Does nothing visible in a
      ;; one-colony world, which is most of them, and is the whole of the
      ;; interface for a world with several.
      ((#\t #\T)
       (let ((n (length (world-colonies *live-world*))))
         (when (plusp n)
           (setf *live-colony* (mod (1+ *live-colony*) n))
           (let ((c (nth *live-colony* (world-colonies *live-world*))))
             (format t "~&watching colony ~d of ~d: ~a~%"
                     (1+ *live-colony*) n (colony-name c))))))
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

(defun live-drop-food (px py)
  "Put a food source where the cursor is (§5.5).

Nothing about this reaches into the colony: a source is a fact about the
*world*, and the ants have to find it the same way they find any other —
by walking into it.  No ant is told it appeared, no trail is seeded, and
the arrival of a fresh source is therefore a real test of whether search
still works once a colony has committed to a road somewhere else."
  (when (and *live-world* *live-view*)
    (multiple-value-bind (wx wy) (view-screen->world *live-view* px py)
      ;; Outside the arena is a miss rather than an error: the view can be
      ;; zoomed out past the world's edge, and a source placed there would
      ;; sit where no ant can reach and quietly look like a bug.
      (if (and (<= 0.0f0 wx (world-width *live-world*))
               (<= 0.0f0 wy (world-height *live-world*)))
          (let ((f (add-food *live-world* wx wy
                             *live-food-radius* *live-food-amount*)))
            (format t "~&food: ~,0f units at (~,3f ~,3f)~%"
                    (food-amount f) wx wy))
          (format t "~&food: (~,3f ~,3f) is outside the arena~%" wx wy)))))

(defun live-drop-block (px py)
  "Drop a square of terrain where the cursor is (§5.5).

The counterpart to LIVE-DROP-FOOD, and deliberately the same shape of
intervention: it changes the *world* and tells no ant that anything has
happened.  Nothing reroutes a trail, nothing clears the pheromone that
now runs into a wall, and no ant is informed that the road it has been
walking for ten minutes is shut.  What happens next is the model's
answer, which is the only reason to have the key.

The pheromone already laid on the covered cells does go, because
ADD-OBSTACLE rasterizes into the mask and FIELD-STEP! forces a blocked
cell to zero — chemistry cannot sit inside a rock.  The trail *up to* the
wall survives and keeps recruiting ants to it, which is the interesting
half: a colony walks into its own obstruction for as long as the trail
outlives it."
  (when (and *live-world* *live-view*)
    (multiple-value-bind (wx wy) (view-screen->world *live-view* px py)
      (if (>= *live-blocks* *live-block-limit*)
          (live-note "block: ~d is the limit — see *live-block-limit*"
                     *live-block-limit*)
          (multiple-value-bind (poly why)
              (add-block *live-world* wx wy *live-block-half*)
            (cond
              (poly (incf *live-blocks*) (live-note nil))
              ((eq why :nest)
               (live-note "block: not over a nest entrance — it would seal ~
                           the colony in"))
              ((eq why :outside)
               (live-note "block: (~,3f ~,3f) is outside the arena" wx wy))
              (t (live-note "block: refused (~a)" why))))))))

(defun live-poke-nest (px py)
  "Disturb the nest under the cursor (§3.3, §5.5).

The interaction §3.3 names when it introduces the alarm field — \"poke
the nest, watch it erupt\" — and the only thing in this model that ever
releases alarm.  Nothing in the simulation attacks a colony, so without
this key the fourth chemical would be a mechanism with no precondition,
which is precisely the trap three of M4's additions fell into.

It touches no ant.  Alarm goes onto the ground over the entrance and
every part of what follows is ants reading a chemical, which is the only
reason the eruption is worth watching rather than merely animating."
  (when (and *live-world* *live-view*)
    (multiple-value-bind (wx wy) (view-screen->world *live-view* px py)
      (let ((c (world-nest-at *live-world* wx wy *live-poke-slack*)))
        (if c
            (progn (poke-nest! *live-world* c)
                   (live-note "poked ~a" (colony-name c)))
            (live-note "poke: no nest at (~,3f ~,3f)" wx wy))))))

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
      ;; The readout is drawn in the window (LIVE-DRAW-HUD), not printed:
      ;; a terminal you cannot see while looking at the ants is no use.
      ;; Clicking empty space clears the selection.
      (if (and best (< best-d2 (* 0.02f0 0.02f0)))
          (setf *live-selected* best
                *live-selected-id* (aref (ants-id a) best))
          (setf *live-selected* nil)))))

(defun ant-state-name (s &optional (waited 0))
  "The state's name, except that IN NEST is two different situations and
the panel should not call them the same thing.

An ant resting with a full tank is between trips.  An ant resting *under*
the bar it needs to set out is not resting at all — it is waiting to be
fed, and cannot work until it is.  Those look identical in the table and
read identically on a map, which is precisely how a nest quietly filling
with ants that cannot leave got mistaken for a nest full of ants
declining to (§3.5).  So the panel names the second one."
  (case s
    (0 (if (plusp waited) "WAITING FOR FOOD" "IN NEST"))
    (1 "OUTBOUND") (2 "AT FOOD") (3 "RETURNING")
    (t "DEAD")))

(defun ant-state-rgb (s &optional (waited 0))
  (when (and (= s 0) (plusp waited))
    ;; the same red the map uses for an ant that cannot set out, so the
    ;; panel and the picture say the same thing about the same ant
    (return-from ant-state-rgb (values 0.95f0 0.25f0 0.22f0)))
  (case s
    (1 (values 0.86f0 0.88f0 0.92f0))
    (2 (values 0.95f0 0.90f0 0.70f0))
    (3 (values 1.00f0 0.72f0 0.30f0))
    (t (values 0.62f0 0.68f0 0.78f0))))

(defparameter *live-keys*
  '(("+ -"   "SPEED")
    ("SPACE" "PAUSE")
    ("HOME"  "FIT")
    ("WHEEL" "ZOOM")
    ("DRAG"  "PAN")
    ("CLICK" "INSPECT")
    ("A"     "ADD FOOD")
    ("O"     "OBSTACLE")
    ("P"     "POKE NEST")
    ("H"     "HIDE")
    ("N"     "NEST")
    ("C"     "CONTACT")
    ("T"     "TRIBE")
    ("Q"     "QUIT"))
  "The key legend, in the order it is drawn.  Kept as data rather than a
run of HUD-TEXT calls so the panel can size itself to its contents — the
font is fixed-width, so the widest row *is* the panel width, and a legend
that has to be re-measured by hand every time a line changes is a legend
that will eventually be clipped.")

(defun live-draw-keyhelp (h vw vh)
  "The key legend, pinned to the bottom-right corner (§5.1).

Bottom-right because the top edge is the counter strip and the top-left
is where the inspector panel opens; this is the one corner nothing else
competes for, at any window size."
  (declare (type hud h))
  (let* ((s 2.0f0)
         (adv (* 4.0f0 s))               ; the font's fixed advance
         (line 13.0f0)
         (pad 9.0f0)
         (gap 10.0f0)
         (kw (* adv (reduce #'max *live-keys* :key (lambda (r) (length (first r))))))
         (aw (* adv (reduce #'max *live-keys* :key (lambda (r) (length (second r))))))
         (pw (+ pad kw gap aw pad))
         (ph (+ pad (* line (length *live-keys*)) pad))
         (px (- vw pw 10.0f0))
         (py (- vh ph 10.0f0)))
    (hud-quad h px py pw ph 0.04 0.045 0.055 0.80)
    (hud-quad h px py 3.0 ph 0.55 0.86 1.00 0.55)
    (loop for (key action) in *live-keys*
          for row from 0
          for y = (+ py pad (* row line))
          do (hud-text h (+ px pad) y key
                       :scale s :r 0.90 :g 0.76 :b 0.50)
             (hud-text h (+ px pad kw gap) y action
                       :scale s :r 0.60 :g 0.66 :b 0.74))))

(defun live-draw-marker (h sx sy)
  "Mark the inspected ant: four pink arms around it, pulsing.

An ant is a disc four pixels across in a field of several hundred of
them, so the marker has to win on every channel at once — size, hue and
motion.  The first version was a small white cross, and white is the
colour of an *ordinary outbound ant*: it read as one more ant.  Pink is
the only hue nothing in the simulation uses, so it cannot be mistaken for
state.

Four arms with a gap rather than a cross, because a cross drawn over a
4-pixel disc hides the thing it is pointing at.

The pulse runs on GLFW's clock rather than the simulation's, so it keeps
blinking while the world is paused — which is exactly when someone is
most likely to be hunting for the ant they just clicked."
  (declare (type hud h))
  (let* ((tsec (glfw:get-time))
         (pulse (+ 0.45f0 (* 0.55f0 (abs (sin (* 3.6f0 tsec))))))
         (arm 16.0f0) (gap 7.0f0) (th 3.0f0) (half (* 0.5f0 th))
         (r 1.0f0) (g 0.24f0) (b 0.78f0))
    (hud-quad h (- sx gap arm) (- sy half) arm th r g b pulse)
    (hud-quad h (+ sx gap)     (- sy half) arm th r g b pulse)
    (hud-quad h (- sx half) (- sy gap arm) th arm r g b pulse)
    (hud-quad h (- sx half) (+ sy gap)     th arm r g b pulse)))

(defun live-draw-hud (h w vw vh fps)
  "Counters along the top, and the selected ant's state readout (§5.1)."
  (declare (type hud h) (type world w))
  (hud-reset h)
  (let* ((cs (world-colonies w))
         (c (nth (min *live-colony* (max 0 (1- (length cs)))) cs))
         (s 2.0f0)
         (line 14.0f0))
    ;; --- counters -----------------------------------------------------
    (hud-quad h 0 0 vw 26 0.03 0.035 0.04 0.72)
    (let ((x 10.0f0))
      (setf x (hud-text h x 8 (format nil "T ~,1FS" (world-seconds w))
                        :scale s :r 0.66 :g 0.72 :b 0.80))
      (when (cdr cs)
        ;; Only when there is more than one; a single-colony HUD has
        ;; nothing to disambiguate and the row would be noise.
        (setf x (hud-text h (+ x 14) 8
                          (format nil "~:@(~a~)" (if c (colony-name c) "-"))
                          :scale s :r 0.55 :g 0.90 :b 0.68)))
      ;; The species, when the scenario named one.  Between the colony
      ;; name and the counters, because it qualifies every number to its
      ;; right: 400 ants of one animal is not 400 of the other.
      (when *live-species*
        (setf x (hud-text h (+ x 14) 8
                          (format nil "~:@(~a~)" *live-species*)
                          :scale s :r 0.90 :g 0.66 :b 0.45)))
      (setf x (hud-text h (+ x 14) 8
                        (format nil "ANTS ~D" (if c (colony-population c) 0))
                        :scale s))
      (setf x (hud-text h (+ x 14) 8
                        (format nil "STOCK ~D"
                                (round (if c (colony-stock c) 0.0)))
                        :scale s :r 0.72 :g 0.86 :b 0.60))
      (setf x (hud-text h (+ x 14) 8
                        (format nil "TRAIL ~D"
                                (round (if c (field-total (colony-field c)) 0)))
                        :scale s :r 0.55 :g 0.86 :b 1.00))
      (setf x (hud-text h (+ x 14) 8
                        (format nil "~,2FX~:[~; PAUSED~]" *live-speed*
                                *live-paused*)
                        :scale s :r 0.90 :g 0.76 :b 0.50))
      (hud-text h (+ x 14) 8 (format nil "~D FPS" (round fps))
                :scale s :r 0.50 :g 0.55 :b 0.62))

    ;; --- selected ant -------------------------------------------------
    (let ((a (world-ants w)) (b (world-bodies w)) (i *live-selected*))
      (when (and i (ant-live-p a i)
                 (= (aref (ants-id a) i) *live-selected-id*))
        (let* ((px 10.0f0) (py 38.0f0)
               (pw 232.0f0) (ph 194.0f0)
               (st (aref (ants-state a) i))
               (tx (+ px 10.0f0))
               (ty (+ py 10.0f0)))
          (hud-quad h px py pw ph 0.04 0.045 0.055 0.86)
          ;; a state-coloured stripe down the left, so the mode reads
          ;; before any of the text does
          (multiple-value-bind (r g bl) (ant-state-rgb st)
            (hud-quad h px py 4.0 ph r g bl 0.95))
          (hud-text h tx ty (format nil "ANT ~D" (aref (ants-id a) i))
                    :scale s)
          (let ((waited (aref (ants-waited a) i))
                (ttl (aref (ants-alarm-ttl a) i))
                (cool (aref (ants-alarm-cool a) i)))
            ;; Alarm is deliberately not a state (§3.3): the ant keeps its
            ;; errand and stops acting on it.  That is right for the model
            ;; and wrong for the panel, which would label an ant OUTBOUND
            ;; while it is in fact running from a poke — the same
            ;; misreading ANT-STATE-NAME exists to prevent, and the same
            ;; answer: say the thing that is actually happening.
            ;;
            ;; The stripe down the left stays *state*-coloured, so the
            ;; errand is not lost — the panel says what the ant is doing
            ;; in text and what it will go back to in colour.
            (cond
              ((plusp ttl)
               (hud-text h tx (+ ty line) "ALARMED"
                         :scale s :r 1.00 :g 0.55 :b 0.20)
               (hud-text h (+ tx 148) (+ ty line)
                         (format nil "~,1Fs" (* ttl *motion-dt*))
                         :scale s :r 1.00 :g 0.55 :b 0.20))
              ;; Habituated, and worth showing rather than hiding: an ant
              ;; standing in a plume and ignoring it looks like a bug
              ;; until the panel says it is deaf on purpose.
              ((plusp cool)
               (hud-text h tx (+ ty line) "SETTLING"
                         :scale s :r 0.72 :g 0.45 :b 0.30)
               (hud-text h (+ tx 148) (+ ty line)
                         (format nil "~,1Fs" (* cool *motion-dt*))
                         :scale s :r 0.72 :g 0.45 :b 0.30))
              (t
               (multiple-value-bind (r g bl) (ant-state-rgb st waited)
                 (hud-text h tx (+ ty line) (ant-state-name st waited)
                           :scale s :r r :g g :b bl))
               ;; and for how long, in seconds rather than ticks: the panel
               ;; is read by a person, and the rest of it is in seconds
               (when (plusp waited)
                 (hud-text h (+ tx 148) (+ ty line)
                           (format nil "~,1Fs" (* waited *motion-dt*))
                           :scale s :r 0.95 :g 0.25 :b 0.22)))))
          ;; Energy, crop and confidence as bars: all three are bounded,
          ;; and a bar reads faster than a number for anything bounded.
          ;;
          ;; **Energy and crop are not two views of one quantity**, and
          ;; the panel puts them next to each other because that is the
          ;; single most misreadable thing about an ant.  Energy is the
          ;; ant's own fuel; the crop is the *social stomach*, food it is
          ;; carrying for the colony and cannot spend on itself.  An ant
          ;; can starve with a full crop, which is why §3.5 keeps them as
          ;; separate fields, and a reader who has not been told that will
          ;; assume a full ant is a fed one.
          (let* ((cc (aref (coerce (world-colonies w) 'vector)
                           (aref (ants-colony a) i)))
                 (gate (colony-energy-threshold cc))
                 (resolve (aref (ants-resolve a) i))
                 (fed-line (* *trophallaxis-threshold* gate)))
            (hud-text h tx (+ ty (* 2 line)) "ENERGY" :scale s
                      :r 0.60 :g 0.66 :b 0.74)
            (hud-bar h (+ tx 62) (+ ty (* 2 line)) 118 8
                     (aref (ants-energy a) i) 0.95 0.55 0.35)
            ;; and the three lines that energy is judged against, marked
            ;; on the bar itself (HUD-BAR-TICK).  Hunger is not a stored
            ;; quantity in this model — it is the level read against a
            ;; threshold that moves with the colony — so without these the
            ;; bar cannot answer the only question anyone asks of it.
            ;;
            ;;   white   can this ant set out at all
            ;;   amber   where it will give up and turn for home, which is
            ;;           carried per ant and so differs between two ants
            ;;           standing side by side (ANTS-RESOLVE)
            ;;   green   below this a nestmate will feed it in the field
            ;;
            ;; At the shipped defaults the green line sits exactly on the
            ;; white one, because *trophallaxis-threshold* is 1.0 of the
            ;; departure bar.  That is worth seeing rather than hiding:
            ;; the two coincide by decision, not by accident.
            (hud-bar-tick h (+ tx 62) (+ ty (* 2 line)) 118 8
                          fed-line 0.55 0.85 0.55)
            (hud-bar-tick h (+ tx 62) (+ ty (* 2 line)) 118 8
                          resolve 0.95 0.76 0.35)
            (hud-bar-tick h (+ tx 62) (+ ty (* 2 line)) 118 8
                          gate 1.0 1.0 1.0))
          (hud-text h tx (+ ty (* 3 line)) "CROP" :scale s
                    :r 0.60 :g 0.66 :b 0.74)
          (hud-bar h (+ tx 62) (+ ty (* 3 line)) 118 8
                   (aref (ants-crop a) i) 0.55 0.80 0.95)
          ;; What nestmates have told this ant lately (M3).  Not a
          ;; direction and never one: a contact says that ants are coming
          ;; back loaded, which is evidence about *when* rather than
          ;; *where*, and all it buys is a longer willingness to keep
          ;; going (*encounter-resolve-gain*).
          (hud-text h tx (+ ty (* 4 line)) "NEWS" :scale s
                    :r 0.60 :g 0.66 :b 0.74)
          (hud-bar h (+ tx 62) (+ ty (* 4 line)) 118 8
                   (aref (ants-confidence a) i) 0.70 0.55 0.95)
          ;; Age in seconds, not ticks.  Everything else on this panel is
          ;; in seconds and a reader should not have to divide by 20 to
          ;; compare two rows of it.
          (hud-text h tx (+ ty (* 5 line))
                    (format nil "AGE ~,0FS  MET ~D"
                            (* (aref (ants-age a) i) *motion-dt*)
                            (aref (ants-met a) i))
                    :scale s :r 0.60 :g 0.66 :b 0.74)
          ;; the home vector, as its length -- the direction is better
          ;; seen on the map than read as two numbers
          (let ((hx (aref (ants-hvx a) i)) (hy (aref (ants-hvy a) i)))
            (hud-text h tx (+ ty (* 6 line))
                      (format nil "HOME ~,1FCM"
                              (* 100.0 (sqrt (+ (* hx hx) (* hy hy)))))
                      :scale s :r 0.60 :g 0.66 :b 0.74))
          ;; The lifelong traits, which cost no storage at all: pace and
          ;; handedness are pure functions of the ant's id (ANT-PACE,
          ;; ANT-HANDEDNESS), so an individual can be characterised
          ;; without the table carrying a byte for it.  Worth showing
          ;; because they are the answer to 'why is this one behaving
          ;; differently from the one beside it'.
          (let ((id (aref (ants-id a) i))
                (seed (world-seed w)))
            (hud-text h tx (+ ty (* 7 line))
                      (format nil "PACE ~,2FX  HAND ~:[L~;R~]"
                              (ant-pace id seed)
                              (plusp (ant-handedness id seed)))
                      :scale s :r 0.60 :g 0.66 :b 0.74))
          ;; The last meal shared with a named nestmate (M3).
          ;;
          ;; Trophallaxis is the one thing an ant does that involves
          ;; another *individual* rather than a field or itself, and it
          ;; lasts a tick at a time — so it is held for *partner-memory*
          ;; and then goes quiet, rather than flashing for 50 ms.
          (let ((ttl (aref (ants-partner-ttl a) i)))
            (when (plusp ttl)
              (let ((gave (= 1 (aref (ants-partner-gave a) i))))
                (hud-text h tx (+ ty (* 8 line))
                          (format nil "~:[FED BY~;FED~] #~D"
                                  gave (aref (ants-partner a) i))
                          :scale s
                          :r (if gave 0.55 0.95)
                          :g (if gave 0.80 0.76)
                          :b (if gave 0.95 0.35)))))
          ;; Can this ant set out at all?
          ;;
          ;; The energy bar alone does not answer that, because the bar
          ;; the ant is measured against moves: the threshold falls as
          ;; the colony gets hungry (COLONY-ENERGY-THRESHOLD).  Reading
          ;; the bar without knowing where the line sits is what made a
          ;; nest full of exhausted ants look like a nest full of ants
          ;; refusing to leave.  So the panel states the verdict and the
          ;; number it was reached against.
          (let* ((cc (aref (coerce (world-colonies w) 'vector)
                           (aref (ants-colony a) i)))
                 (gate (colony-energy-threshold cc))
                 (ablep (> (aref (ants-energy a) i) gate)))
            (hud-text h tx (+ ty (* 9 line))
                      (format nil "~:[SPENT~;READY~] NEEDS ~,2F"
                              ablep gate)
                      :scale s
                      :r (if ablep 0.60 0.95)
                      :g (if ablep 0.80 0.30)
                      :b (if ablep 0.55 0.26)))
          ;; and mark it on the map, or a panel about an ant you cannot
          ;; find is only half an answer
          (let ((bi (aref (ants-body a) i)))
            (multiple-value-bind (sx sy)
                (view-world->screen *live-view*
                                    (aref (bodies-x b) bi)
                                    (aref (bodies-y b) bi))
              (live-draw-marker h sx sy))))))

    ;; --- key legend ---------------------------------------------------
    (when *live-keyhelp*
      (live-draw-keyhelp h vw vh)))
  (hud-draw h vw vh))

(defun live-title (w fps)
  (let ((c (nth (min *live-colony* (max 0 (1- (length (world-colonies w)))))
                (world-colonies w))))
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
  a            drop a food source at the cursor
  n            resting ants: collide with each other, or pass through
  c            ant-ant contact on or off — terrain, food and corpses
               still block, so this isolates the crowd from the
               navigation (see *ant-collision*)
  space        pause
  + / -        time compression, halving and doubling
  home         frame the whole world
  h / ?        show or hide the key legend
  q / escape   quit

Returns the world, so a session can keep poking at it afterwards."
  (declare (type world w))
  (glfw:with-init-window (:title title :width width :height height
                          :context-version-major 4
                          :context-version-minor 5
                          :opengl-profile :opengl-core-profile
                          ;; The window draws into framebuffer 0 and not
                          ;; into the multisampled offscreen target, so it
                          ;; has to ask for its own samples or the ant of
                          ;; §5.2 is the one thing in the project that is
                          ;; aliased — in the one place it is actually
                          ;; moving, where a staircase on a leg reads as a
                          ;; twitch rather than as a step.
                          :samples *msaa-samples*
                          :opengl-forward-compat t)
    (when (plusp *msaa-samples*) (gl:enable :multisample))
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
            *live-hud* (make-hud)
            *live-selected* nil
            *live-blocks* 0
            *live-note* nil
            *live-colony* 0
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
                        (draw-world r w *live-view* :colony *live-colony*)
                        (live-draw-hud *live-hud* w
                                       (view-vw *live-view*)
                                       (view-vh *live-view*)
                                       fps)
                        (glfw:swap-buffers)
                        (glfw:poll-events)
                        (incf title-timer dt)
                        (when (> title-timer 0.25f0)
                          (setf title-timer 0.0f0)
                          (glfw:set-window-title (live-title w fps))))))
        (when *live-hud* (destroy-hud *live-hud*))
        (destroy-renderer r)
        (setf *live-world* nil *live-renderer* nil *live-hud* nil))))
  w)

;;; Determinism is a property of the *model*, not of the window: the same
;;; seed must give the same run, and §4.2 has a test that says so.  But a
;;; playground where every session is the identical run is a worse
;;; playground, and the two are not in tension — a seed is an argument.
;;;
;;; So both entry points take one, and the window prints it.  A run worth
;;; keeping can then be replayed exactly, which is the whole point of
;;; having the seed be an argument rather than a clock reading.

(defun fresh-seed ()
  "A seed nobody chose, for a session nobody intends to reproduce.

Taken from the clock rather than from *RANDOM-STATE*, which the model
bans outright (§4.2) — but note the ban is on the *simulation* having a
hidden source of randomness, not on a human picking a number.  This runs
once, before the world exists, and its output is then an ordinary seed
like any other.  Nothing downstream can tell where it came from, which is
the property that matters."
  (logand #xFFFFFFFF
          (hash32 (logand #xFFFFFFFF
                          (logxor (get-universal-time)
                                  (get-internal-real-time))))))

(defun live-seed (seed)
  "Resolve a requested seed: NIL means a fresh one."
  (if seed (logand #xFFFFFFFF seed) (fresh-seed)))

(defun live-scenario (path &key (width 1100) (height 800) seed)
  "Open the window on a scenario file (§6).

The playground half of the scenario format.  A format whose only consumer
is a headless test is a format nobody will notice is wrong; being able to
watch a file run is how a scenario gets debugged, and it is why the
bridge apparatus is worth having as a file at all rather than only as a
Lisp constructor.

SEED overrides the file's own; with none, a fresh one is drawn, so one
scenario can be watched as many different runs without editing it.  That
matters most for the bridges, where the whole result is that the outcome
*varies with the seed* — watching the same arm win every time would teach
exactly the wrong lesson.

The scenario's parameter overrides are bound around the whole run, not
just around loading — a file that sets tau and then runs under the
default tau would be a particularly quiet lie."
  ;; The seed has to be given to LOAD-SCENARIO rather than assigned
  ;; afterwards: it is fixed when the world is built, and by the time a
  ;; scenario is loaded WORLD-SEED-POPULATION! has already placed the
  ;; starting ants with it.
  (let* ((s (load-scenario path :seed (live-seed seed)))
         (w (scenario-world s)))
    (format t "~&~a: ~,2f x ~,2f m, ~d colon~:@p, ~d source~:p~@[, ~a~]~%~
                 seed ~d   (repeat this run with SEED=~d)~%"
            (scenario-name s) (world-width w) (world-height w)
            (length (scenario-colonies s)) (length (scenario-foods s))
            (scenario-species s)
            (world-seed w) (world-seed w))
    ;; The species goes on the HUD rather than only in the banner, because
    ;; the banner scrolls away and the question it answers — why is this
    ;; colony behaving nothing like the last one — gets asked ten minutes
    ;; in.  NIL for a file that named none, and the row is then absent
    ;; rather than saying "lasius-niger" at a scenario that did not.
    (let ((*live-species* (scenario-species s)))
      (with-scenario-params (s)
        (run-live w :width width :height height
                    :title (format nil "antsim — ~a" (scenario-name s)))))))

(defun live-demo (&key (width 1100) (height 800) seed)
  "The scenario the M2 gallery renders, but watchable.  A single colony,
one food source, one obstacle — enough to see a trail form, thicken and
carry traffic."
  ;; Nest low and centre, food across most of the arena — 35 cm, about 90
  ;; body lengths, so the trail is a road rather than a smudge and the
  ;; obstacle is a real detour rather than a bump.  Deliberately further
  ;; than the first version: at 18 cm the outbound and returning traffic
  ;; overlapped into one blob and there was nothing to watch.
  (let* ((s (live-seed seed))
         (w (make-world :width 0.6f0 :height 0.6f0 :capacity 8000 :seed s))
         (c (add-colony w :name "home" :nest-x 0.30f0 :nest-y 0.08f0
                          :nest-r 0.02f0 :capacity 3000 :stock 500.0f0)))
    (add-food w 0.34f0 0.43f0 0.03f0 2500.0f0 :quality 1.0f0)
    (add-obstacle w '(0.12 0.20 0.30 0.20 0.30 0.235 0.12 0.235))
    (world-seed-population! w c 150)
    (format t "~&seed ~d   (repeat this run with SEED=~d)~%" s s)
    (run-live w :width width :height height)))
