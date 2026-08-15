;;;; antsim-gl-preload.asd
;;;;
;;;; Deliberately a separate primary system in its own file.  The renderer
;;;; pulls this in with :defsystem-depends-on, which is the only ASDF hook
;;;; that runs before ordinary dependencies — and it has to, because the
;;;; whole point is to load the GPU driver's libGL before cl-opengl can
;;;; bind a different one (see src/render/preload.lisp, and README §5.4).
;;;; Defining it inside antsim.asd would make that a circular dependency on
;;;; the very file being loaded.

(defsystem "antsim-gl-preload"
  :description "Load the GPU driver's libEGL/libGL before cl-opengl binds Mesa's."
  :depends-on ("cffi")
  :pathname "src/render"
  :components ((:file "preload")))
