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
   #:hash32 #:rnd-u32 #:rnd01 #:rnd-normal #:+default-seed+
   ;; pool — persistent workers (§4.5)
   #:pool #:make-worker-pool #:pool-run #:pool-shutdown #:pool-n
   ;; params — the Lasius niger set (§3.1); all rebindable, see params.lisp
   #:*cell-size* #:*motion-dt* #:*pheromone-dt* #:*colony-dt*
   #:*ant-radius* #:*walk-speed* #:*walk-speed-laden* #:*turn-sigma*
   #:*speed-spread*
   #:*gait-stride* #:*ant-disc-pixels* #:*ant-detail-pixels*
   #:*sensor-offset* #:*sensor-spread*
   #:*choice-n* #:*choice-k* #:*choice-eavesdrop*
   #:*trail-tau* #:*trail-cap* #:*trail-deposit* #:*trail-quality-threshold*
   #:*trail-decay-scale* #:trail-tau #:trail-deposit-rate
   #:*trail-packet-spacing* #:*trail-packet-radius* #:*trail-packet-falloff*
   #:*leave-probability* #:*forage-ration* #:*forage-urgency-gain*
   #:*desperate-energy-fraction*
   #:*energy-drain-walking* #:*energy-drain-resting*
   #:*energy-return-threshold* #:*crop-fill-rate* #:*crop-to-energy*
   #:*max-age-ticks* #:*brood-per-stock* #:*nest-upkeep*
   #:*pi-noise* #:*homing-weight-low-energy* #:*nest-arrival-radius*
   #:*nest-exit-scatter* #:*obstacle-avoidance* #:*homing-scan-steps*
   #:*forager-expendability* #:*resting-ants-block*
   #:*trail-homing-suppression*
   #:*brood-reserve-ration* #:*brood-investment*
   #:*queen-lay-rate* #:*brood-development-minutes*
   #:*forager-maturity-ticks* #:*age-shade-ticks*
   #:colony-brood-pipe #:colony-brood-head
   #:*trail-lost-threshold* #:*trail-follow-threshold* #:*trail-memory-decay*
   #:*uturn-ticks* #:*uturn-cast-gain*
   #:*stall-window* #:*stall-pinned-fraction* #:*stall-detour-fraction*
   ;; the no-entry field (§3.9, docs/navigation.md Layer 3)
   #:*repel-tau* #:*repel-deposit* #:*repel-cap* #:*repel-weight*
   #:*repel-threshold* #:*repel-dead-end* #:repel-tau
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
   #:field-deposit-packet!
   #:field-total #:field-max #:field-rasterize-polygon!
   #:field-cell-x #:field-cell-y #:field-tau #:field-cap
   ;; world/bodies — the one non-overlap rule (§3.11)
   #:bodies #:make-bodies #:bodies-alloc #:bodies-free! #:bodies-resolve!
   #:bodies-become-corpse! #:bodies-rebuild-hash!
   #:bodies-n #:bodies-capacity #:bodies-x #:bodies-y #:bodies-r
   #:bodies-kind #:bodies-hash #:bodies-nfree
   #:body-kind-blocking-p #:body-kind-movable-p
   #:+body-ant+ #:+body-corpse+ #:+body-food+ #:+body-nest+
   #:+body-resting+ #:+body-free+
   #:*leave-probability* #:*nest-feed-rate* #:*nest-meals-per-tick*
   #:*forager-eats-at-source*
   ;; world/scene — what a scenario names (§6)
   #:food #:food-x #:food-y #:food-r #:food-amount #:food-initial
   #:food-density #:food-density-for
   #:food-quality #:food-renew #:food-empty-p #:food-body
   #:colony #:colony-id #:colony-name #:colony-field #:colony-repel
   #:colony-stock
   #:colony-population #:colony-capacity #:colony-born #:colony-died
   #:colony-nest-x #:colony-nest-y #:colony-nest-r #:colony-alive-p
   #:colony-forage-urgency #:colony-leave-probability
   #:colony-energy-threshold #:colony-giveup-threshold
   #:food-current-radius
   #:world #:make-world #:world-width #:world-height #:world-bodies
   #:world-ants #:world-colonies #:world-foods #:world-obstacles
   #:world-tick #:world-seed #:world-seconds #:world-food-at
   #:add-obstacle #:add-food #:add-colony
   ;; ant/state — the ant table (§3.5)
   #:ants #:make-ants #:ants-n #:ants-live #:ants-capacity #:ant-live-p
   #:ants-id #:ants-body #:ants-colony #:ants-state #:ants-heading
   #:ants-crop #:ants-load-quality #:ants-energy #:ants-age
   #:ants-hvx #:ants-hvy #:ants-px #:ants-py #:ants-count-state
   #:ants-trailed #:ants-exit #:ants-smelled #:ants-cast #:ants-resolve
   #:ants-gait #:ants-waited
   ;; Layer 0 — one window, three readings (§3.4, docs/navigation.md)
   #:ants-h0x #:ants-h0y #:ants-walked #:ants-window #:ants-stalled
   #:stall-reset! #:stall-step!
   #:path-integration-step!
   #:spawn-ant #:kill-ant
   #:+ant-in-nest+ #:+ant-outbound+ #:+ant-at-food+ #:+ant-returning+
   #:+ant-dead+
   ;; ant/step — the tick (§3.2-§3.5, §4.3)
   ;; scenario — the JSON format (§6); defined in antsim/scenario
   #:scenario #:scenario-name #:scenario-world #:scenario-colonies
   #:scenario-foods #:scenario-seed #:scenario-duration #:scenario-params
   #:load-scenario #:load-scenario-string #:with-scenario-params
   #:scenario-error #:scenario-error-path #:scenario-error-detail
   ;; world/bridge — the §3.8 apparatus
   #:add-bridge!
   #:bridge #:make-bridge-world #:binary-bridge #:double-bridge
   #:bridge-world #:bridge-colony #:bridge-wall-y #:bridge-gaps
   #:bridge-counts #:bridge-lengths
   #:bridge-tally! #:bridge-run! #:bridge-reset-counts!
   #:bridge-share #:bridge-winner
   ;; ant/step — the tick (§3.2-§3.5, §4.3)
   #:wrap-angle #:angle-toward #:sense-at #:choose-turn
   #:repel-at #:repel-deposit! #:clear-bearing
   #:ant-handedness #:ant-pace
   #:world-step! #:world-run! #:colony-step! #:colony-feed! #:world-seed-population!
   ;; render/png (antsim/render)
   #:write-png #:crc32 #:adler32
   ;; render/egl
   #:gl-context #:make-headless-context #:destroy-gl-context
   #:with-headless-gl #:with-gl-traps-masked #:gl-info
   #:gl-context-width #:gl-context-height
   ;; render/offscreen
   #:offscreen #:make-offscreen #:destroy-offscreen #:with-offscreen
   #:offscreen-fbo #:offscreen-width #:offscreen-height
   #:offscreen-samples #:offscreen-resolve-fbo #:resolve-offscreen
   #:*msaa-samples*
   #:bind-offscreen #:read-offscreen #:capture-offscreen
   #:compile-shader #:link-program
   ;; render/antmesh — the articulated ant (§5.2)
   #:ant-mesh #:build-ant-mesh #:ant-mesh-verts #:ant-mesh-index
   #:ant-mesh-nvert #:ant-mesh-nindex
   #:ant-mesh-under-count #:ant-mesh-body-count
   #:+ant-vertex-floats+ #:*legs*
   #:*ant-vertex-glsl* #:*ant-fragment-glsl* #:build-ant-vertex-glsl
   ;; render/smoke — the M0 acceptance frame
   #:draw-smoke-frame #:render-smoke-png #:m0-smoke
   ;; render/view — the ortho camera (§5.5)
   #:view #:make-view #:view-fit #:view-cx #:view-cy #:view-span
   #:view-vw #:view-vh #:view-span-y #:view-bounds
   #:view-world->screen #:view-screen->world
   #:view-zoom-at! #:view-pan-pixels!
   ;; render/renderer — the 2D scene (§5.1)
   #:renderer #:make-renderer #:destroy-renderer
   #:upload-field #:upload-bodies #:upload-ants #:draw-world
   #:ant-display-state #:ant-display-flick #:render-world-png
   ;; render/hud — screen-space overlay (§5.1)
   #:hud #:make-hud #:destroy-hud #:hud-reset #:hud-quad #:hud-text
   #:hud-bar #:hud-draw #:build-font #:*font-3x5*
   ;; render/gallery — the README images (§7, M2)
   #:render-gallery #:gallery-world #:gallery-shot #:gallery-traffic-x
   #:*gallery-directory*
   ;; live/window — the interactive view (§5.5), system antsim/live
   #:run-live #:live-demo #:live-scenario #:live-inspect
   #:*live-speed* #:*live-paused*))
