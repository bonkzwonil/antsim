;;;; util.lisp — shared types and array constructors.
;;;;
;;;; Everything numeric in the core lives in specialized simple-arrays,
;;;; allocated once when the world is built.  README §4.2 rule: no
;;;; allocation inside a tick.  Declaring the element type is not a
;;;; micro-optimisation here — an unspecialized array of single-floats
;;;; boxes every element, which is both slower and a garbage source in the
;;;; one loop that must not produce garbage.
;;;;
;;;; Carried over from waldameisen, where it earned its keep.

(in-package #:antsim)

(deftype f32 () 'single-float)
(deftype f32v () '(simple-array single-float (*)))
(deftype u32v () '(simple-array (unsigned-byte 32) (*)))
(deftype u16v () '(simple-array (unsigned-byte 16) (*)))
(deftype u8v  () '(simple-array (unsigned-byte 8) (*)))
(deftype fixv () '(simple-array fixnum (*)))

(defun mkf32 (n &optional (v 0.0f0))
  (make-array n :element-type 'single-float :initial-element v))
(defun mku32 (n &optional (v 0))
  (make-array n :element-type '(unsigned-byte 32) :initial-element v))
(defun mku16 (n &optional (v 0))
  (make-array n :element-type '(unsigned-byte 16) :initial-element v))
(defun mku8 (n &optional (v 0))
  (make-array n :element-type '(unsigned-byte 8) :initial-element v))
(defun mkfix (n &optional (v 0))
  (make-array n :element-type 'fixnum :initial-element v))

(declaim (inline clampf lerpf sqf))

(defun clampf (x lo hi)
  (declare (type f32 x lo hi))
  (max lo (min hi x)))

(defun lerpf (a b tt)
  (declare (type f32 a b tt))
  (+ a (* tt (- b a))))

(defun sqf (x)
  "X squared.  Named because squared distances are everywhere in the
collision pass (§3.11) and `(* x x)` on a long expression reads badly."
  (declare (type f32 x))
  (* x x))
