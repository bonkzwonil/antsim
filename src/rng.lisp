;;;; rng.lisp — counter-based RNG (README §4.4).
;;;;
;;;; A pure function of (id, tick, stream, seed): no shared state, no
;;;; sequence position, nothing to advance.  That buys four things the
;;;; simulation actually depends on.
;;;;
;;;;   * Order independence.  An ant's draws are the same whichever worker
;;;;     thread happened to step it, and whichever order the range split
;;;;     put it in.  A stateful generator makes threaded runs
;;;;     irreproducible the moment two threads draw from it.
;;;;   * Replay.  Any tick can be recomputed without replaying the ticks
;;;;     before it, which is what makes a failing acceptance run
;;;;     debuggable.
;;;;   * Thread safety by construction, with no lock in the hot loop.
;;;;   * Replicates.  §3.8's symmetry-breaking test is a statement about a
;;;;     *distribution* over runs — "the colony commits to one branch" is
;;;;     only meaningful across many independent repetitions of the same
;;;;     scenario.  That is what SEED is for.
;;;;
;;;; `*random-state*` is therefore banned from simulation code, and the
;;;; test suite pins the exact numbers this produces so a well-meaning
;;;; "improvement" to the mixing cannot silently invalidate a stored run.
;;;;
;;;; Two changes from waldameisen's version, both of which this project
;;;; needs and that one did not:
;;;;
;;;; STREAM — a single ant needs several *independent* uniforms within one
;;;; tick: a turn angle, a trail-choice draw, a decision to leave the
;;;; nest.  Reusing one value for all of them correlates behaviours that
;;;; must not be correlated.  Numbering the draws is cheaper and clearer
;;;; than threading a counter through the call chain.
;;;;
;;;; SEED — see replicates above.  It is an argument rather than a special
;;;; variable on purpose: a `let`-bound special is thread-local in SBCL, so
;;;; worker threads would silently keep using the global value and every
;;;; replicate would come out identical.  Passing it keeps the function
;;;; pure and the bug impossible.

(in-package #:antsim)

;;; Distinct odd multipliers, one per coordinate.  Odd, so multiplication
;;; mod 2^32 stays a bijection and no information is lost before mixing.
(defconstant +knuth32+  2654435761)     ; Knuth's multiplicative constant
(defconstant +tick32+   3266489917)     ; Murmur3 c2
(defconstant +stream32+ 2246822519)     ; Murmur3 c1

(defconstant +default-seed+ 2166136261
  "FNV-1a offset basis.  Any nonzero value would do; what matters is that
it is not zero — see the fixed-point note on RND-U32.")

(declaim (inline hash32 rnd-u32 rnd01))

(defun hash32 (x)
  "Murmur3 32-bit finaliser: an avalanche mix, not a random source on its
own.  Flipping any input bit changes about half the output bits.

Note that HASH32(0) = 0.  Every step is a shift-xor or a multiply, and
all of them fix zero.  This is a property of the function, not a bug in
it, but it is a trap for anything that feeds it small numbers — which is
exactly what a simulation keyed on (id, tick) does."
  (declare (type (unsigned-byte 32) x)
           (optimize (speed 3) (safety 0)))
  (let ((h x))
    (declare (type (unsigned-byte 32) h))
    (setf h (logand #xFFFFFFFF (logxor h (ash h -16))))
    (setf h (logand #xFFFFFFFF (* h 2246822507)))
    (setf h (logand #xFFFFFFFF (logxor h (ash h -13))))
    (setf h (logand #xFFFFFFFF (* h 3266489909)))
    (logand #xFFFFFFFF (logxor h (ash h -16)))))

(defun rnd-u32 (id tick &optional (stream 0) (seed +default-seed+))
  "A well-mixed 32-bit word keyed on (ID, TICK, STREAM, SEED).

Three rounds, one per coordinate, rather than one round over a combined
key.  Two reasons, and the first is not theoretical:

  * HASH32 fixes zero, so a single-round mix would hand ant 0 on tick 0
    the value 0 — and RND01 would return exactly 0.0, the one value a
    half-open uniform is most likely to be special-cased on.  Starting
    from a nonzero seed removes the fixed point outright.
  * Folding all three coordinates in at once leaves visible structure for
    small ids and small stream numbers, which is precisely the range the
    simulation lives in on every tick.

The cost is two extra multiply-shift chains per draw, which does not
register next to the field sampling in the same loop."
  (declare (type (unsigned-byte 32) id tick stream seed)
           (optimize (speed 3) (safety 0)))
  (let* ((h (hash32 (logxor seed (logand #xFFFFFFFF (* id +knuth32+)))))
         (h (hash32 (logxor h (logand #xFFFFFFFF (* tick +tick32+))))))
    (declare (type (unsigned-byte 32) h))
    (hash32 (logxor h (logand #xFFFFFFFF (* stream +stream32+))))))

(defun rnd01 (id tick &optional (stream 0) (seed +default-seed+))
  "Uniform [0,1) as a single-float, keyed on (ID, TICK, STREAM, SEED).

The top 24 bits are used, which is exactly the precision a single-float
mantissa holds: taking more would add bits that rounding discards, and
taking the *low* bits of a hash rather than the high ones is a classic
way to inherit whatever structure the mixer failed to destroy."
  (declare (type (unsigned-byte 32) id tick stream seed)
           (optimize (speed 3) (safety 0)))
  (* (float (ash (rnd-u32 id tick stream seed) -8) 1.0f0)
     5.9604645f-8))                     ; 2^-24
