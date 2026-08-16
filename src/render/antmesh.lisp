;;;; render/antmesh.lisp — the ant, as geometry (§5.2).
;;;;
;;;; One mesh, built once at load and instanced.  This file owns the
;;;; *anatomy*: where the segments are, where the legs attach, how long a
;;;; femur is.  The vertex shader owns the *articulation*, and it reads
;;;; the limb tables below rather than repeating them, so the drawing and
;;;; the skeleton cannot drift apart (BUILD-ANT-VERTEX-GLSL splices them
;;;; into the source).
;;;;
;;;; Everything here is in **ant radii** — the collision radius of §3.11 is
;;;; the unit, so the mesh is scale-free and one instance float sizes it.
;;;; The frame is the ant's: +x is the way it is walking, +y is its left.
;;;;
;;;;         antennae (2, swept, and bent by what they smell)
;;;;            \  /
;;;;           ,-----.       head + mandibles
;;;;           `--+--'
;;;;          ,---+---.      mesosoma — the six legs attach here
;;;;       /  `---+---'  \   3 pairs, alternating tripod
;;;;      /       o       \  petiole node
;;;;           ,-----.
;;;;           |     |       gaster
;;;;           `-----'
;;;;
;;;; The vertex format is four attributes and one of them is overloaded:
;;;;
;;;;   0  a_pos    vec2   rest position, radii   (body segments)
;;;;   1  a_uv     vec2   outward normal, unit   (body segments)
;;;;                      OR (t, w) along a limb (legs, antennae)
;;;;   2  a_part   float  which piece this is — see the +PART-...+ list
;;;;   3  a_shade  float  a flat multiplier, for pieces that are just darker
;;;;
;;;; The normal is carried per vertex rather than derived because it is
;;;; what lights the ant: rotated into world space and dotted with a fixed
;;;; light, it turns four flat fans into four rounded, glossy segments for
;;;; the cost of one dot product.  A top-down ant with no shading reads as
;;;; a paper cutout, and the whole point of §5.2 is that it should not.
;;;;
;;;; Index order is *draw* order, because there is no depth buffer:
;;;;
;;;;   [0 .. under)          the six legs      — beneath the body
;;;;   [under .. body)       gaster, petiole, mesosoma, head
;;;;   [body .. total)       mandibles, antennae, payload, deposit mark
;;;;
;;;; which is also what makes the level of detail free: the simplified
;;;; body-only ant of §5.2 is the middle range on its own, so the two
;;;; meshes are one mesh and can never disagree about where the gaster is.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Parts
;;; --------------------------------------------------------------------
;;;
;;; These numbers cross into GLSL.  They are the contract between this
;;; file and *ANT-VERTEX-GLSL*, and nothing else may renumber them.

(defconstant +part-gaster+   0)
(defconstant +part-petiole+  1)
(defconstant +part-mesosoma+ 2)
(defconstant +part-head+     3)
(defconstant +part-mandible+ 4)
(defconstant +part-payload+  5)
(defconstant +part-deposit+  6)
(defconstant +part-leg+     10)         ; +10..+15, L1 L2 L3 R1 R2 R3
(defconstant +part-antenna+ 20)         ; +20, +21, left and right

;;; --------------------------------------------------------------------
;;; The anatomy, in ant radii
;;; --------------------------------------------------------------------
;;;
;;; Proportioned on a Lasius niger minor worker seen from directly above
;;; (§3.1): the gaster is the biggest single mass, the mesosoma carries
;;; every leg, and the head is very nearly as wide as it is long.  Total
;;; length comes out at about 2.3 radii — a shade over one body length,
;;; because the collision radius is half a body length by definition and
;;; the mandibles stick out past it.

(defparameter *gaster-centre* -0.62f0)
(defparameter *gaster-front*   0.30f0)  ; the waisted end, toward the petiole
(defparameter *gaster-back*    0.54f0)
(defparameter *gaster-width*   0.32f0)

(defparameter *petiole-x*     -0.24f0)  ; the pivot the gaster swings on
(defparameter *petiole-r*      0.09f0)

;; Narrower than either of the other two, and that is the whole
;; silhouette: three masses with a waist between each pair is what makes a
;; shape read as an ant rather than as a beetle.  It is also true — the
;; mesosoma is the narrowest part of a Lasius worker seen from above.
(defparameter *meso-centre*    0.14f0)
(defparameter *meso-front*     0.32f0)
(defparameter *meso-back*      0.34f0)
(defparameter *meso-width*     0.205f0)

(defparameter *neck-x*         0.42f0)  ; the pivot the head turns on
;; Longer than it is wide, just: a Lasius head is subquadrate, and a head
;; drawn round reads as a bead on a string rather than as the front of an
;; animal.
(defparameter *head-centre*    0.74f0)
(defparameter *head-front*     0.30f0)
(defparameter *head-back*      0.30f0)
(defparameter *head-width*     0.27f0)

(defparameter *mandible-x*     1.06f0)  ; where a carried crumb sits
(defparameter *gaster-tip-x*  -1.14f0)  ; where a packet goes down

(defparameter *segment-outline* 0.045f0
  "How far a dark copy of each body segment is drawn behind it, in radii.

Cheap, and it does more for legibility than anything else in this file.
The pheromone field is the brightest thing on the screen by design (§5.3)
and pale ants sit on top of it; without a dark edge a crowd of them melts
into one another and into the trail.  It scales with the ant, so it
disappears by itself at the zoom levels where it would only be mud.")

;;; Legs.  Hip on the mesosoma, foot where it rests at mid-stride, and the
;;; two link lengths.  KNEE is the side the femur-tibia joint bows to,
;;; which is outward in every case: a knee that folds inward puts the leg
;;; through the ant's own body, and the difference is the whole silhouette.
;;;
;;; PHASE is the alternating tripod of §5.2 — L1/R2/L3 swing together
;;; while R1/L2/R3 hold the ground, then they swap.  It is the one thing
;;; in this table that is a *fact* rather than a proportion.
;;;
;;; Order: L1 L2 L3 R1 R2 R3.  The right legs are the left ones mirrored
;;; in y, which flips the handedness of the bend, hence the negated KNEE.
;;;
;;; The link lengths are only a little longer than the hip-to-foot
;;; distance they have to span, and that is deliberate.  Generous links
;;; give a hairpin knee, six of them cross in the middle, and the ant
;;; comes out a spider; just enough slack gives the shallow outward bow
;;; that is actually what an ant's leg looks like from above.  They still
;;; have to reach the ends of the stride, so the slack is set by
;;; *GAIT-STRIDE* and not by taste.
(defparameter *legs*
  ;;    hip-x   hip-y   foot-x  foot-y  femur  tibia  knee  phase
  '((    0.34    0.17     0.66    0.62   0.44   0.40   1.0   0.0)   ; L1
    (    0.14    0.20     0.16    0.86   0.46   0.42  -1.0   0.5)   ; L2
    (   -0.06    0.18    -0.56    0.78   0.56   0.52  -1.0   0.0)   ; L3
    (    0.34   -0.17     0.66   -0.62   0.44   0.40  -1.0   0.5)   ; R1
    (    0.14   -0.20     0.16   -0.86   0.46   0.42   1.0   0.0)   ; R2
    (   -0.06   -0.18    -0.56   -0.78   0.56   0.52   1.0   0.5))) ; R3

(defparameter *leg-width-root* 0.046f0)
(defparameter *leg-width-tip*  0.016f0)

;;; Antennae.  Geniculate, like every ant's: a long scape out of the head,
;;; an elbow, then the funiculus that does the actual smelling.  The rest
;;; angles are measured from straight ahead and mirrored by side.
(defparameter *antenna-base-x*  0.82f0)
(defparameter *antenna-base-y*  0.20f0)
(defparameter *antenna-scape*   0.42f0)
(defparameter *antenna-funic*   0.50f0)
(defparameter *antenna-angle-1* 0.45f0) ; scape, outward from forward
(defparameter *antenna-angle-2* 0.60f0) ; funiculus, further outward again
(defparameter *antenna-sweep*   0.34f0) ; amplitude of the resting sweep
(defparameter *antenna-rate*    3.2f0)  ; sweeps per second
(defparameter *antenna-bend*    0.55f0) ; how far a gradient pulls it (§3.4)
(defparameter *antenna-probe*   0.006f0) ; metres either side of the tip
;; Finer than the legs, and they have to be: an antenna that reads as a
;; seventh leg is worse than no antenna, because the sweep then looks
;; like a limp.
(defparameter *antenna-width-root* 0.036f0)
(defparameter *antenna-width-tip*  0.013f0)

;;; --------------------------------------------------------------------
;;; Building it
;;; --------------------------------------------------------------------

(defstruct (ant-mesh (:constructor %make-ant-mesh))
  "Interleaved vertices (6 floats each) and a triangle index list, plus
the two range boundaries the level of detail selects between."
  (verts nil :type (or null f32v))
  (index nil :type (or null u32v))
  (nvert 0 :type fixnum)
  (nindex 0 :type fixnum)
  (under-count 0 :type fixnum)          ; indices drawn beneath the body
  (body-count 0 :type fixnum))          ; the body-only LOD, after those

(defconstant +ant-vertex-floats+ 6)

(defstruct (mesh-builder (:constructor %make-mesh-builder))
  (verts nil) (index nil))

(defun make-mesh-builder ()
  (%make-mesh-builder
   :verts (make-array 1024 :element-type 'single-float :adjustable t :fill-pointer 0)
   :index (make-array 1024 :element-type '(unsigned-byte 32) :adjustable t :fill-pointer 0)))

(defun mb-nvert (mb)
  (floor (fill-pointer (mesh-builder-verts mb)) +ant-vertex-floats+))

(defun mb-vertex! (mb x y nx ny part shade)
  "Append one vertex and return its index."
  (let ((v (mesh-builder-verts mb))
        (i (mb-nvert mb)))
    (vector-push-extend (float x 1.0f0) v)
    (vector-push-extend (float y 1.0f0) v)
    (vector-push-extend (float nx 1.0f0) v)
    (vector-push-extend (float ny 1.0f0) v)
    (vector-push-extend (float part 1.0f0) v)
    (vector-push-extend (float shade 1.0f0) v)
    i))

(defun mb-tri! (mb a b c)
  (let ((ix (mesh-builder-index mb)))
    (vector-push-extend a ix)
    (vector-push-extend b ix)
    (vector-push-extend c ix)))

(defun mb-nindex (mb) (fill-pointer (mesh-builder-index mb)))

(defun mb-oval! (mb cx cy front back ry n part shade)
  "A fan for one body segment: an ellipse whose two halves may differ in
length, which is what turns a circle into a gaster.

The rim carries its outward normal, and the centre carries a zero one.
The vertex shader reads the length of that normal to decide how much of
the lighting term to apply, so a flat centre and a lit rim come out of
one expression with no branch."
  (let ((centre (mb-vertex! mb cx cy 0.0 0.0 part shade))
        (rim (make-array n)))
    (dotimes (i n)
      (let* ((th (* 2.0f0 (float pi 1.0f0) (/ (float i 1.0f0) n)))
             (c (cos th)) (s (sin th))
             (rx (if (plusp c) front back))
             (px (+ cx (* rx c)))
             (py (+ cy (* ry s)))
             ;; the ellipse normal, which is not the radial direction
             (nx (/ c rx)) (ny (/ s ry))
             (len (max 1.0f-6 (sqrt (+ (* nx nx) (* ny ny))))))
        (setf (aref rim i)
              (mb-vertex! mb px py (/ nx len) (/ ny len) part shade))))
    (dotimes (i n)
      (mb-tri! mb centre (aref rim i) (aref rim (mod (1+ i) n))))))

(defun mb-unit-fan! (mb n part shade)
  "A unit disc at the origin.  The shader places and sizes it — this is
the carried crumb and the deposit mark, both of which have a radius that
changes every frame and a position that does not."
  (let ((centre (mb-vertex! mb 0.0 0.0 0.0 0.0 part shade))
        (rim (make-array n)))
    (dotimes (i n)
      (let* ((th (* 2.0f0 (float pi 1.0f0) (/ (float i 1.0f0) n)))
             (c (cos th)) (s (sin th)))
        (setf (aref rim i) (mb-vertex! mb c s c s part shade))))
    (dotimes (i n)
      (mb-tri! mb centre (aref rim i) (aref rim (mod (1+ i) n))))))

(defun mb-limb! (mb part)
  "Six vertices along a two-link limb, as (t, w) pairs in the normal
slot: t runs 0 at the root, 1 at the joint, 2 at the tip, and w is the
side, -1 or +1.  Four triangles.

The shader solves for the joint and mitres the outline there, so a leg
that is bent double still has a clean elbow rather than a notch."
  (let ((v (make-array 6)))
    (dotimes (k 3)
      (let ((tt (float k 1.0f0)))
        (setf (aref v (* k 2)) (mb-vertex! mb 0.0 0.0 tt -1.0 part 1.0)
              (aref v (1+ (* k 2))) (mb-vertex! mb 0.0 0.0 tt 1.0 part 1.0))))
    (dotimes (k 2)
      (let ((a (aref v (* k 2))) (b (aref v (1+ (* k 2))))
            (c (aref v (+ 2 (* k 2)))) (d (aref v (+ 3 (* k 2)))))
        (mb-tri! mb a b c)
        (mb-tri! mb b d c)))))

(defun mb-mandible! (mb side)
  "One curved blade, four vertices and two triangles.  Small, and the
reason the head reads as a head rather than a bead."
  (let* ((s (float side 1.0f0))
         (a (mb-vertex! mb 0.98 (* s 0.185)  0.0 s +part-mandible+ 1.0))
         (b (mb-vertex! mb 1.10 (* s 0.160)  0.2 (* s 0.98) +part-mandible+ 1.0))
         (c (mb-vertex! mb 1.19 (* s 0.040)  0.9 (* s 0.44) +part-mandible+ 1.0))
         (d (mb-vertex! mb 1.00 (* s 0.095) -0.3 (* s -0.95) +part-mandible+ 1.0)))
    (if (plusp s)
        (progn (mb-tri! mb a b c) (mb-tri! mb a c d))
        (progn (mb-tri! mb a c b) (mb-tri! mb a d c)))))

(defun build-ant-mesh ()
  "The mesh of §5.2, in draw order: legs, then body, then everything that
sits on top of it."
  (let ((mb (make-mesh-builder))
        under body)
    ;; --- under: the six legs -----------------------------------------
    (dotimes (i 6) (mb-limb! mb (+ +part-leg+ i)))
    (setf under (mb-nindex mb))

    ;; --- the body itself, back to front ------------------------------
    ;;
    ;; Back to front because the segments overlap at the joints and the
    ;; front one should win: an ant's head sits over its neck, not under
    ;; it.  Each is drawn twice, a dark oversized copy first — see
    ;; *SEGMENT-OUTLINE* — which also gives every joint a contact shadow
    ;; for nothing, because the copy in front covers the one behind.
    (flet ((segment (cx front back ry n part)
             (let ((m *segment-outline*))
               (mb-oval! mb cx 0.0 (+ front m) (+ back m) (+ ry m) n part 0.26))
             (mb-oval! mb cx 0.0 front back ry n part 1.0)))
      (segment *gaster-centre* *gaster-front* *gaster-back* *gaster-width*
               16 +part-gaster+)
      (segment *petiole-x* *petiole-r* *petiole-r* (* 0.9 *petiole-r*)
               7 +part-petiole+)
      (segment *meso-centre* *meso-front* *meso-back* *meso-width*
               13 +part-mesosoma+)
      (segment *head-centre* *head-front* *head-back* *head-width*
               13 +part-head+))
    (setf body (- (mb-nindex mb) under))

    ;; --- over: appendages, cargo, and the deposit mark ----------------
    (mb-mandible! mb  1)
    (mb-mandible! mb -1)
    (mb-limb! mb (+ +part-antenna+ 0))
    (mb-limb! mb (+ +part-antenna+ 1))
    (mb-unit-fan! mb 10 +part-payload+ 1.0)
    (mb-unit-fan! mb 8 +part-deposit+ 1.0)

    (%make-ant-mesh
     :verts (coerce (mesh-builder-verts mb) '(simple-array single-float (*)))
     :index (coerce (mesh-builder-index mb) '(simple-array (unsigned-byte 32) (*)))
     :nvert (mb-nvert mb)
     :nindex (mb-nindex mb)
     :under-count under
     :body-count body)))
