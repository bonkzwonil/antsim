;;;; antsim.asd
;;;;
;;;; Four systems, and the split is the one from docs/concept.md §4.1: the numeric
;;;; core has no dependencies at all, so the simulation can be built and
;;;; tested on a machine with no GPU and no graphics stack.  Only
;;;; antsim/render knows that OpenGL exists.

(defsystem "antsim"
  :description "A 2D ant colony simulation on real behavioural science — numeric core."
  :author "Mathias Menzel-Nielsen"
  ;; The single source of truth for the version.  The build script stamps
  ;; it into the binary, both packaging scripts name their output from it,
  ;; and both release workflows refuse a tag that disagrees with it — see
  ;; docs/shipping.md.
  :version "1.0.1"        ; M4 — the society; route memory now keeps the whole walk
  :depends-on ()                        ; core stays dependency-free (sb-thread only)
  :serial t
  :pathname "src"
  :components
  ((:file "package")
   (:file "util")
   (:file "rng")
   (:file "pool")
   (:file "params")
   ;; Deliberately a flat, explicit order rather than two modules.  The
   ;; ant *table* has no knowledge of the world and must be built before
   ;; MAKE-WORLD can allocate one; the ant *tick* needs colonies, bodies
   ;; and fields and therefore comes last.  Splitting them across the
   ;; world files is what keeps the dependency acyclic without a single
   ;; forward declaration.
   (:file "ant/state")
   (:file "world/geom")
   (:file "world/grid")
   (:file "world/bodies")
   (:file "world/scene")
   (:file "ant/step")
   ;; The §3.8 bridge apparatus.  Last, because it builds worlds and runs
   ;; ticks and therefore needs everything above it — and because nothing
   ;; above it may depend on an experiment.
   (:file "world/bridge")
   ;; The rest of §3.8's apparatus: Beckers' two sources, and §3.12's two
   ;; colonies over one contested pile.  Same rule as the bridges —
   ;; nothing above may depend on an experiment.
   (:file "world/trials"))
  :in-order-to ((test-op (test-op "antsim/test"))))

(defsystem "antsim/scenario"
  :description "The JSON scenario format (§6).  Owns the JSON dependency."
  ;; §4.1: the core never sees a parser.  This is the only system that
  ;; knows JSON exists, and nothing in `antsim` depends on it.
  :depends-on ("antsim" "com.inuoe.jzon")
  :serial t
  :pathname "src/scenario"
  :components ((:file "load")))

(defsystem "antsim/render"
  :description "Headless GL 4.1 via EGL/GLFW, offscreen targets, PNG capture."
  ;; antsim-gl-preload lives in its own .asd and is pulled in here, not in
  ;; :depends-on, because it must load *before* cl-opengl — see
  ;; src/render/preload.lisp.
  :defsystem-depends-on ("antsim-gl-preload")
  :depends-on ("antsim" "cffi" "cl-opengl" #+darwin "cl-glfw3")
  :serial t
  :pathname "src/render"
  :components ((:file "png")
               (:file "egl")
               (:file "offscreen")
               (:file "smoke")
               (:file "view")
               ;; Before the shaders, and it has to be: the ant's vertex
               ;; program is *generated* from the skeleton in here (§5.2),
               ;; so that the mesh and the articulation cannot drift apart.
               (:file "antmesh")
               (:file "shaders")
               (:file "renderer")
               (:file "hud")
               (:file "gallery"))
  :in-order-to ((test-op (test-op "antsim/render-test"))))

(defsystem "antsim/live"
  :description "Interactive window: GLFW, ortho camera, zoom and pan (§5.5)."
  ;; The same preload as the headless path, and for the same reason: the
  ;; window's GL and the process's GL have to be one implementation (§5.4).
  :defsystem-depends-on ("antsim-gl-preload")
  ;; antsim/scenario so the window is a playground for scenario *files*
  ;; and not only for worlds written in Lisp — §6's format is worth very
  ;; little if the only way to look at one is to render it headless.
  :depends-on ("antsim/render" "antsim/scenario" "cl-glfw3")
  :serial t
  :pathname "src/live"
  :components ((:file "window")))

(defsystem "antsim/app"
  :description "The shipped program: argv, usage, exit codes (see docs/shipping.md)."
  ;; The only system that knows a *program* exists.  Everything below it
  ;; is a library, and stays one: nothing in antsim/live may depend on
  ;; this, or the window could no longer be opened from a REPL without
  ;; dragging a command-line parser in with it.
  :depends-on ("antsim/live")
  :serial t
  :pathname "src/app"
  :components ((:file "main")))

(defsystem "antsim/test"
  :description "Test suite for the antsim core.  No GPU required."
  ;; antsim/scenario, not just antsim: the shipped bridge scenarios must be
  ;; checked against the Lisp constructors, and a test that cannot read the
  ;; files cannot do that.  The *core* still has no parser (§4.1).
  :depends-on ("antsim" "antsim/scenario" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "suite")
               (:file "world")
               (:file "bodies")
               (:file "ant")
               (:file "scenario")
               ;; Its own FiveAM suite, not part of `antsim`: these are
               ;; colony runs over several seeds and they are slow, so
               ;; `make test` stays fast and `make acceptance` is what
               ;; says the science works.
               (:file "acceptance"))
  :perform (test-op (o c)
             (symbol-call :fiveam :run!
                          (find-symbol (string :antsim) :antsim/test))))

(defsystem "antsim/app-test"
  :description "The shipped binary's command line.  Needs GLFW to load, no GPU."
  ;; Its own system rather than part of antsim/test, because antsim/app
  ;; reaches antsim/live and cl-glfw3 opens libglfw when it is *loaded*.
  ;; The core suite must stay runnable on a machine with no graphics stack
  ;; at all (§4.1), and a test file that quietly imposes one would take
  ;; that away from it.
  :depends-on ("antsim/app" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "app"))
  :perform (test-op (o c)
             (symbol-call :fiveam :run!
                          (find-symbol (string :app) :antsim/app-test))))

(defsystem "antsim/render-test"
  :description "Renderer tests.  GL tests skip when no context is available."
  :depends-on ("antsim/render" "fiveam")
  :serial t
  :pathname "tests"
  :components ((:file "render")
               (:file "view"))
  :perform (test-op (o c)
             (symbol-call :fiveam :run!
                          (find-symbol (string :render) :antsim/render-test))))
