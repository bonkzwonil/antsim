;;;; package.lisp
;;;;
;;;; One package for the whole project, exported symbol by symbol.  The
;;;; simulation is a small number of large flat tables (README §4.2), not a
;;;; class hierarchy, and splitting that across packages buys nothing but
;;;; qualified names in the tick loop.

(defpackage #:antsim
  (:use #:cl)
  (:nicknames #:ant)
  (:export
   ;; util — types and array constructors
   #:f32 #:f32v #:u32v #:u16v #:u8v #:fixv
   #:mkf32 #:mku32 #:mku16 #:mku8 #:mkfix
   #:clampf #:lerpf #:sqf
   ;; rng — counter-based, no global state (§4.4)
   #:hash32 #:rnd-u32 #:rnd01 #:+default-seed+
   ;; pool — persistent workers (§4.5)
   #:pool #:make-worker-pool #:pool-run #:pool-shutdown #:pool-n
   ;; params — the Lasius niger set (§3.1); all rebindable, see params.lisp
   #:*cell-size* #:*motion-dt* #:*pheromone-dt* #:*colony-dt*
   #:*ant-radius* #:*walk-speed* #:*walk-speed-laden* #:*turn-sigma*
   #:*sensor-offset* #:*sensor-spread*
   #:*choice-n* #:*choice-k* #:*choice-eavesdrop*
   #:*trail-tau* #:*trail-cap* #:*trail-deposit* #:*trail-quality-threshold*
   #:*energy-drain-walking* #:*energy-drain-resting*
   #:*energy-return-threshold* #:*crop-fill-rate* #:*crop-to-energy*
   #:*max-age-ticks* #:*brood-per-stock* #:*nest-upkeep*
   #:*pi-noise* #:*homing-weight-low-energy* #:*nest-arrival-radius*
   #:*relax-iterations* #:*relax-slop*
   ;; world/geom — polygons and the broad phase (§3.7, §4.2)
   #:polygon #:make-polygon #:polygon-n #:polygon-verts
   #:polygon-min-x #:polygon-min-y #:polygon-max-x #:polygon-max-y
   #:point-in-polygon-p #:polygon-closest-point #:disc-polygon-correction
   #:shash #:make-shash #:shash-build #:shash-bucket #:do-shash-neighbours
   #:shash-w #:shash-h #:shash-starts #:shash-items
   ;; world/grid — the pheromone field (§3.3)
   #:field #:make-field #:field-w #:field-h #:field-c #:field-cell
   #:field-index #:field-at #:field-blocked-p #:field-deposit! #:field-step!
   #:field-total #:field-max #:field-rasterize-polygon!
   #:field-cell-x #:field-cell-y #:field-tau #:field-cap
   ;; render/png (antsim/render)
   #:write-png #:crc32 #:adler32
   ;; render/egl
   #:gl-context #:make-headless-context #:destroy-gl-context
   #:with-headless-gl #:with-gl-traps-masked #:gl-info
   #:gl-context-width #:gl-context-height
   ;; render/offscreen
   #:offscreen #:make-offscreen #:destroy-offscreen #:with-offscreen
   #:offscreen-fbo #:offscreen-width #:offscreen-height
   #:bind-offscreen #:read-offscreen #:capture-offscreen
   #:compile-shader #:link-program
   ;; render/smoke — the M0 acceptance frame
   #:draw-smoke-frame #:render-smoke-png #:m0-smoke))
