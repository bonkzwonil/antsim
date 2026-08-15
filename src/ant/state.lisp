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
