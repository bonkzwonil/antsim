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
  ;; --- when two ants meet (M3) ----------------------------------------
  ;;
  ;; Evidence from nestmates that persisting is currently paying, 0..1,
  ;; decaying every tick.  Raised by meeting a laden nestmate coming the
  ;; other way.
  ;;
  ;; It is emphatically **not** a direction, and the field is named for
  ;; what it is so that nothing later is tempted to steer with it.  Ants
  ;; of this genus were tested for tactile transfer of direction and the
  ;; result was negative; what a contact honestly carries is that ants are
  ;; coming back loaded, which is a statement about time rather than
  ;; space.  See *ENCOUNTER-CONFIDENCE*.
  (confidence nil :type (or null f32v))
  ;; Buffered outputs of the encounter pass, applied after the sweep.
  ;;
  ;; The same discipline as the collision solver's Jacobi buffers (§3.11)
  ;; and the field's deposit buffer (§3.3), and for the same reason: an
  ;; ant that read a neighbour's heading *after* that neighbour had
  ;; already turned would make the result depend on table order, which is
  ;; a determinism bug that only shows up when something else changes.
  ;; Every encounter reads the state the tick began with and writes here.
  (dturn nil :type (or null f32v))
  (dcrop nil :type (or null f32v))
  (denergy nil :type (or null f32v))
  ;; Body index -> ant index, so an encounter found through the broad
  ;; phase can be turned back into an ant.
  ;;
  ;; The broad phase indexes *bodies* — ants, corpses, food and nest
  ;; entrances in one table (§3.11) — and until an encounter was an event
  ;; nothing ever needed to go the other way.  Sized to the body table,
  ;; and every lookup is checked against the ant's own BODY entry rather
  ;; than trusted, so a stale slot can only ever be ignored.
  (of-body nil :type (or null u32v))
  ;; How many nestmates this ant has met, for its whole life.
  ;;
  ;; Not display state: encounter *rate* is the quantity a large part of
  ;; the literature on task allocation is about, and until now the model
  ;; produced encounters and counted none of them.  One counter per ant is
  ;; the cheapest possible way to have the number at all.
  (met nil :type (or null u32v))
  ;; Who this ant last shared food with, and which way it went — id in
  ;; PARTNER, 1 = gave / 2 = received in PARTNER-GAVE, and a countdown in
  ;; PARTNER-TTL so the inspector can hold the event on screen for a
  ;; readable moment instead of flashing it for one 50 ms tick.
  ;;
  ;; This is display state and is admitted as such, like ANTS-GAIT: no
  ;; rule reads it.  It is here because a trophallaxis is the one thing
  ;; an ant does that involves *another named individual*, and a model
  ;; that cannot say which one has lost the only part of the event a
  ;; person can follow.
  (partner nil :type (or null u32v))
  (partner-ttl nil :type (or null u16v))
  (partner-gave nil :type (or null u8v))
  ;; Per-tick buffer for the receiving half, applied after the sweep.
  ;;
  ;; A donor writes to its *recipient's* slot, which is the one place the
  ;; encounter pass does that, so the write has to be commutative or the
  ;; result depends on table order — two ants feeding the same nestmate on
  ;; the same tick would otherwise record whichever the loop reached last.
  ;; MIN over donor ids is commutative and associative, so the answer is
  ;; the same however the sweep is split (§4.4, §4.5).
  (fed-by nil :type (or null u32v))
  ;; The corpse this ant is carrying, as a body index, or +NO-BODY+.
  ;; Necrophoresis (§3.9, M4): the corpse keeps its body — it is still
  ;; drawn, and an ant hauling one is the whole point of the behaviour —
  ;; but that body is marked carried and drops out of the collision pass,
  ;; because a corpse being held is not a corpse in the way.
  (corpse nil :type (or null u32v))
  ;; The alarm episode (§3.3, M5), as an excitable ant: ALARM-TTL counts
  ;; down while it is alarmed, and ALARM-COOL counts down afterwards,
  ;; during which it neither responds to alarm nor releases any.
  ;;
  ;; **Both of these are the answer to a measurement, not a refinement.**
  ;; The first version had no per-ant state at all: an ant was alarmed
  ;; exactly while it could smell alarm, and released while alarmed.  That
  ;; is a positive feedback with no brake, and it ran away — 400 of 400
  ;; ants alarmed within two minutes of one poke, still alarmed three
  ;; minutes later, the field saturating the whole arena, and 244 of them
  ;; dead of starvation because a permanently frantic ant never forages
  ;; and never goes home to be fed.  A colony that a single poke kills is
  ;; not a model of alarm.
  ;;
  ;; A refractory period is the standard answer and the biological one:
  ;; the response adapts, and an excitable medium without one supports a
  ;; wave that re-enters its own tail for ever.  With it the wave sweeps
  ;; out, passes, and ends.
  (alarm-ttl nil :type (or null u16v))
  (alarm-cool nil :type (or null u16v))
  ;; Ticks this ant has spent in a systematic search (§3.9, M4).  Zero
  ;; whenever it is not searching, so the number always means "unbroken
  ;; ticks since the home vector ran out" — the spiral's radius is a
  ;; function of it, and a lifetime total would make every search after
  ;; the first start at the wrong width.
  (search nil :type (or null u32v))
  ;; The outward path, as up to *route-waypoints* points per ant, laid out
  ;; ant-major: point k of ant i is at (i * stride + k).  Recorded walking
  ;; out and consumed walking back (§3.4, §3.9).
  ;;
  ;; A flat array rather than a per-ant vector for the reason the whole
  ;; table is struct-of-arrays: an ant is a row of indices into shared
  ;; storage, and a per-ant object here would put a pointer chase in the
  ;; middle of the tick.
  (route-x nil :type (or null f32v))
  (route-y nil :type (or null f32v))
  (route-stride 0 :type fixnum)
  (route-n nil :type (or null u8v))      ; points recorded
  (route-i nil :type (or null u8v))      ; which one is being walked back to
  (route-d nil :type (or null f32v))     ; metres since the last point
  ;; The spacing this ant is currently recording at.  Per ant and not a
  ;; parameter because it *doubles* whenever the buffer fills, which is
  ;; how a fixed budget of points can span a journey of any length: the
  ;; route coarsens instead of stopping.  An ant on a 10 cm bridge never
  ;; leaves *route-spacing*; one crossing the five-metre arena ends up
  ;; several doublings above it.
  (route-step nil :type (or null f32v))  ; metres between points, this leg
  (free nil :type (or null fixv))
  (nfree 0 :type fixnum))

(defconstant +no-body+ #xFFFFFFFF
  "No body — an ant carrying no corpse.  The same bit pattern as +NO-ANT+
and deliberately a separate name: one of them indexes the ant table and
the other the body table, and a sentinel that is silently both is a
sentinel that will one day be used against the wrong array.")

(defconstant +no-ant+ #xFFFFFFFF
  "OF-BODY entry for a body that is not a live ant — food, a nest
entrance, or the corpse an ant left behind.")

(defun make-ants (capacity &key (body-capacity capacity))
  "BODY-CAPACITY sizes the reverse map only.  It is a separate argument
because the two tables are conceptually independent — the body table also
holds corpses, food and nest entrances — even though MAKE-WORLD happens to
size them alike."
  (%make-ants :capacity capacity
              :confidence (mkf32 capacity)
              :dturn (mkf32 capacity) :dcrop (mkf32 capacity)
              :denergy (mkf32 capacity)
              :of-body (mku32 body-capacity +no-ant+)
              :met (mku32 capacity)
              :partner (mku32 capacity +no-ant+)
              :partner-ttl (mku16 capacity) :partner-gave (mku8 capacity)
              :fed-by (mku32 capacity +no-ant+)
              :corpse (mku32 capacity +no-body+)
              :search (mku32 capacity)
              :alarm-ttl (mku16 capacity) :alarm-cool (mku16 capacity)
              :route-x (mkf32 (* capacity (max 1 *route-waypoints*)))
              :route-y (mkf32 (* capacity (max 1 *route-waypoints*)))
              :route-stride (max 1 *route-waypoints*)
              :route-n (mku8 capacity) :route-i (mku8 capacity)
              :route-d (mkf32 capacity)
              :route-step (mkf32 capacity *route-spacing*)
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
  ;; The body outlives the ant — it becomes a corpse, and nothing removes
  ;; one (§3.11) — so the reverse map has to be broken here or the broad
  ;; phase would keep handing encounters a dead ant's index.
  (setf (aref (the u32v (ants-of-body a)) (aref (ants-body a) i)) +no-ant+)
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
