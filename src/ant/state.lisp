;;;; ant/state.lisp — the ant table (§3.5, §4.2).
;;;;
;;;; Struct-of-arrays, fixed capacity, allocated once.  Birth and death
;;;; move a slot on and off a free list rather than resizing anything,
;;;; which is precisely why §3.10 makes the population a state variable
;;;; with an upper bound instead of a headcount.
;;;;
;;;; An ant does not store its own position.  It holds an index into the
;;;; body table (§3.11), so the collision sweep walks one contiguous array
;;;; covering ants, corpses and food alike, and there is exactly one place
;;;; a position can be wrong.

(in-package #:antsim)

;;; Four live states and DEAD (§3.5).  There is deliberately no
;;; TRAIL-FOLLOWING: an outbound ant always runs the same rule, and where
;;; there is no pheromone every choice weight is k^n and that rule
;;; degenerates exactly into the correlated random walk.  Exploring and
;;; trail-following are the same behaviour in two environments.
;;;
;;; SEARCHING — the failed-homing spiral — is the fifth state M1 does not
;;; need (§3.9); until then a returning ant keeps its home vector and its
;;; noise and either finds the nest or does not.
(defconstant +ant-in-nest+ 0)
(defconstant +ant-outbound+ 1)
(defconstant +ant-at-food+ 2)
(defconstant +ant-returning+ 3)
(defconstant +ant-dead+ 4)

(defstruct (ants (:constructor %make-ants))
  (n 0 :type fixnum)                    ; high-water mark
  (capacity 0 :type fixnum)
  (live 0 :type fixnum)
  (id nil :type (or null u32v))         ; stable RNG key, unique for life
  (body nil :type (or null u32v))       ; index into the body table
  (colony nil :type (or null u8v))
  (state nil :type (or null u8v))
  (heading nil :type (or null f32v))
  (crop nil :type (or null f32v))
  (load-quality nil :type (or null f32v)) ; quality of the food being carried
  (energy nil :type (or null f32v))
  (age nil :type (or null u32v))
  ;; Path integration (§3.4): the running vector from the ant *to* its
  ;; nest.  Without it the first trail can never be laid, because an ant
  ;; that finds food in virgin territory has no way home and the whole
  ;; recruitment cascade has no seed.
  (hvx nil :type (or null f32v))
  (hvy nil :type (or null f32v))
  ;; Position at the start of the tick, so path integration can be closed
  ;; over the ant's *actual* net displacement after collision resolution
  ;; has had its say.  See PATH-INTEGRATION-STEP! for why that matters.
  (px nil :type (or null f32v))
  (py nil :type (or null f32v))
  ;; Distance walked since this ant last put its gaster down (§3.3).  A
  ;; trail is a row of discrete packets, not a painted stripe, so an ant
  ;; has to remember how far it has come since the last one — laying by
  ;; distance rather than per tick also keeps the trail's strength
  ;; independent of walking speed, which a per-tick deposit does not: a
  ;; laden ant walks slower and would otherwise lay a heavier line for
  ;; the same journey.
  (trailed nil :type (or null f32v))
  ;; Stride phase, 0..1 through one alternating-tripod cycle (§5.2).
  ;;
  ;; Display state, and the only piece of it the ant table carries.  It is
  ;; here rather than in the renderer because it is a *history* — φ
  ;; advances with the distance this ant has walked, and nothing a frame
  ;; can see says how far that is.
  ;;
  ;; Distance and not time, which is the whole point.  During stance a
  ;; foot is planted in world space and slides backward through the body
  ;; frame at exactly the rate the body slides forward; tie φ to the clock
  ;; instead and a stalled ant treadmills on the spot while a fast one
  ;; skates.  Closed over actual net displacement (PATH-INTEGRATION-STEP!)
  ;; rather than the attempted step, for the same reason the home vector
  ;; is: an ant shoving against a crowd is not covering ground, and its
  ;; feet should say so.
  (gait nil :type (or null f32v))
  ;; The bearing this ant sets off on when it next leaves the nest (§3.4).
  ;;
  ;; Route fidelity: an ant that came home from a source remembers roughly
  ;; where it came in from and goes back out that way.  Every ant always
  ;; has one — random at birth, replaced by the real bearing after a
  ;; successful trip — so there is no "no memory" case to special-case.
  (exit nil :type (or null f32v))
  ;; The strongest trail this ant has smelled lately, 0..1, decaying a
  ;; little every tick (§3.2).  An ant cannot notice it has lost a trail
  ;; without remembering that it had one.
  ;;
  ;; A decaying maximum rather than simply the previous tick's reading,
  ;; and the difference is the whole behaviour.  Losing a trail is an
  ;; edge between two *levels* — properly on it, then properly off it —
  ;; and one tick of memory cannot span those, because the smell falls
  ;; through the middle gradually and the tick that crosses the lower
  ;; level always has a reading just above it.  With a one-tick memory
  ;; the rule instead fires whenever an ant brushes any faint trail and
  ;; leaves it, which is most of what ants do.
  (smelled nil :type (or null f32v))
  ;; The energy this ant will push down to before turning for home
  ;; (§3.5), fixed at the moment it last left the nest.
  ;;
  ;; Carried rather than looked up.  How hungry the colony is decides how
  ;; deep a forager digs into its reserve, but an ant crossing open
  ;; ground cannot know how hungry the colony is *now* — the only honest
  ;; way for it to have learnt that is by asking for food while resting
  ;; and being told what there was.  So it learns it at the door and
  ;; commits.  A colony that is fed while this ant is out does not reach
  ;; across the arena and change its mind for it.
  (resolve nil :type (or null f32v))
  ;; Ticks spent resting in the nest below the bar it needs to set out —
  ;; that is, waiting to be fed before it can work again (§3.5).
  ;;
  ;; Displayed rather than acted on, for now.  It is also the number a
  ;; forager would need in order to learn how the colony is doing without
  ;; reading anything colony-wide: an ant that asks for food and is not
  ;; served has been told the larder is thin, and that is the only channel
  ;; a real ant has.  Watching it is the cheapest way to find out whether
  ;; it carries the signal before anything is made to depend on it.
  (waited nil :type (or null u32v))
  ;; Ticks of casting left after a U-turn.  Zero for an ant that is
  ;; walking normally, which is nearly all of them nearly all the time.
  (cast nil :type (or null u8v))
  (free nil :type (or null fixv))
  (nfree 0 :type fixnum))

(defun make-ants (capacity)
  (%make-ants :capacity capacity
              :id (mku32 capacity) :body (mku32 capacity)
              :colony (mku8 capacity) :state (mku8 capacity +ant-dead+)
              :heading (mkf32 capacity) :crop (mkf32 capacity)
              :load-quality (mkf32 capacity)
              :energy (mkf32 capacity) :age (mku32 capacity)
              :hvx (mkf32 capacity) :hvy (mkf32 capacity)
              :px (mkf32 capacity) :py (mkf32 capacity)
              :trailed (mkf32 capacity)
              :gait (mkf32 capacity)
              :exit (mkf32 capacity)
              :smelled (mkf32 capacity) :cast (mku8 capacity)
              :resolve (mkf32 capacity) :waited (mku32 capacity)
              :free (mkfix capacity)))

(declaim (inline ant-live-p))
(defun ant-live-p (a i)
  (declare (type ants a) (type fixnum i))
  (/= (aref (the u8v (ants-state a)) i) +ant-dead+))

(defun ants-alloc (a)
  "Claim a slot, or NIL when the table is full.  Full is a legitimate
state: §3.10 caps the population, and a colony at its cap is thriving,
not broken."
  (declare (type ants a))
  (cond ((plusp (ants-nfree a))
         (decf (ants-nfree a))
         (aref (ants-free a) (ants-nfree a)))
        ((< (ants-n a) (ants-capacity a))
         (prog1 (ants-n a) (incf (ants-n a))))
        (t nil)))

(defun ants-free! (a i)
  (declare (type ants a) (type fixnum i))
  (setf (aref (ants-state a) i) +ant-dead+)
  (setf (aref (ants-free a) (ants-nfree a)) i)
  (incf (ants-nfree a))
  (decf (ants-live a))
  (values))

;;; SPAWN-ANT and KILL-ANT live in ant/step.lisp, not here: they need
;;; colonies and the body table, and this file has to load *before* the
;;; world so that MAKE-WORLD can allocate an ant table.

(defun ants-count-state (a state)
  (declare (type ants a) (type (unsigned-byte 8) state))
  (let ((k 0))
    (dotimes (i (ants-n a) k)
      (when (= (aref (the u8v (ants-state a)) i) state) (incf k)))))
