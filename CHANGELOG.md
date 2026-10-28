# Changelog

## [1.11.1](https://github.com/futo-org/backups/compare/v1.11.0...v1.11.1) (2026-10-28)


### Bug Fixes

* **yucca sdk:** browse a snapshot's files while the post-backup prune holds the lock ([#115](https://github.com/futo-org/backups/issues/115)) ([f020938](https://github.com/futo-org/backups/commit/f0209384141f4c83d628df64a7e272077e593208))

## [1.11.0](https://github.com/futo-org/backups/compare/v1.10.0...v1.11.0) (2026-10-28)


### Features

* **standalone-app:** pass RESTIC_WALK_CONCURRENCY through to restic ([#114](https://github.com/futo-org/backups/issues/114)) ([128e4f3](https://github.com/futo-org/backups/commit/128e4f3986561370f00f674edb0e47b6467c4cd5))
* **standalone-app:** ship restic from futo-org/restic ([#111](https://github.com/futo-org/backups/issues/111)) ([7f13feb](https://github.com/futo-org/backups/commit/7f13febcccc99c2f54b7224bff4d272487d43cf5))


### Bug Fixes

* **yucca sdk:** list snapshots without waiting on the post-backup prune lock ([#112](https://github.com/futo-org/backups/issues/112)) ([e54e1b7](https://github.com/futo-org/backups/commit/e54e1b712a7cbf0423114dfb362bf0411e932ef6))

## [1.10.0](https://github.com/futo-org/backups/compare/v1.9.0...v1.10.0) (2026-10-27)


### Features

* **yucca sdk:** show the stored name of local-backend repositories ([#106](https://github.com/futo-org/backups/issues/106)) ([3f2a7c0](https://github.com/futo-org/backups/commit/3f2a7c0dd73acc8d3a8e95619a0dc15967ec54b3))
* **yucca sdk:** time estimate on dash; better ETAs ([#104](https://github.com/futo-org/backups/issues/104)) ([b9a922d](https://github.com/futo-org/backups/commit/b9a922d25bf5a87d75129a5c160ada8c5ddfb0a3))


### Bug Fixes

* **support-logs-streamer:** export metrics every 15s, under vmagent's idle timeout ([#109](https://github.com/futo-org/backups/issues/109)) ([3f95d03](https://github.com/futo-org/backups/commit/3f95d03fdc9aa7ce392e035e7f8850875d4bd0bb))
* **yucca sdk:** keep the parent snapshot and retention across hostname changes ([#101](https://github.com/futo-org/backups/issues/101)) ([e0a80a7](https://github.com/futo-org/backups/commit/e0a80a79b25bacb4ffb31d45430780bdb4364e88))
* **yucca sdk:** prefix job enum schema ids so hosts' OpenAPI documents don't collide ([#108](https://github.com/futo-org/backups/issues/108)) ([34d3723](https://github.com/futo-org/backups/commit/34d3723f8b8da35f6ac93e3e4d558ac8311921e3))

## [1.9.0](https://github.com/futo-org/backups/compare/v1.8.1...v1.9.0) (2026-10-27)


### Features

* **emails:** mention no storage cap and no billing details in the beta invite ([#76](https://github.com/futo-org/backups/issues/76)) ([98258bc](https://github.com/futo-org/backups/commit/98258bcd4af7010254f9f32854327c3e6af37844))
* **support-logs:** support mode with restic -vv and opt-in log streaming to FUTO ([#105](https://github.com/futo-org/backups/issues/105)) ([8be2a5b](https://github.com/futo-org/backups/commit/8be2a5b564542c24b58882494301effab518bd37))
* **yucca sdk:** confirm before cancelling a running job ([#98](https://github.com/futo-org/backups/issues/98)) ([71f55ae](https://github.com/futo-org/backups/commit/71f55aede3a363c4126807d0d8de53f7f561d792))
* **yucca sdk:** job queue ([#4](https://github.com/futo-org/backups/issues/4)) ([75e9597](https://github.com/futo-org/backups/commit/75e959714c44493091436b1b4ad912dbedb261e0))
* **yucca sdk:** job status UI ([#9](https://github.com/futo-org/backups/issues/9)) ([73ef210](https://github.com/futo-org/backups/commit/73ef210288ea7b5dbe252fc8e4403f32d3d0e22f))
* **yucca sdk:** mark interrupted jobs as incomplete ([#6](https://github.com/futo-org/backups/issues/6)) ([143dbc7](https://github.com/futo-org/backups/commit/143dbc7fadd4c7b3b7d6ad7cc8dc3755cd85b0f9))
* **yucca sdk:** show absolute timestamps in backup history ([#97](https://github.com/futo-org/backups/issues/97)) ([0ae53c0](https://github.com/futo-org/backups/commit/0ae53c021d14f5f809a1251a58c3da6282a098bd))
* **yucca sdk:** tell backups apart in the restore picker and disable empty ones ([#102](https://github.com/futo-org/backups/issues/102)) ([83f23bf](https://github.com/futo-org/backups/commit/83f23bff0afbf0b323eca72cac7d90a73016a6d0))
* **yucca sdk:** warn when a schedule runs more than once an hour ([#99](https://github.com/futo-org/backups/issues/99)) ([4c10758](https://github.com/futo-org/backups/commit/4c1075852bf318174654890799edd15e188259cf))


### Bug Fixes

* **michael:** book a client disconnect as 499, not a backend failure ([#100](https://github.com/futo-org/backups/issues/100)) ([2681e0e](https://github.com/futo-org/backups/commit/2681e0e09e2e347d4f3343babd2908993e395d2b))
* **yucca sdk:** keep retention policy when changing other settings ([#2](https://github.com/futo-org/backups/issues/2)) ([df5373a](https://github.com/futo-org/backups/commit/df5373a0f69802a181d4bb8fe64cbdfd5f6902d3))
* **yucca sdk:** remove deleted repositories from this machine ([#103](https://github.com/futo-org/backups/issues/103)) ([9adc743](https://github.com/futo-org/backups/commit/9adc74331d7bd79be8f81715e8215bb644c9c0cd))
* **yucca sdk:** restore schema on import ([#1](https://github.com/futo-org/backups/issues/1)) ([b07ec8b](https://github.com/futo-org/backups/commit/b07ec8b65a0267ded5e8bbb1ebd9fc317443783b))
* **yucca sdk:** skip snapshot prune if warnings are present ([#3](https://github.com/futo-org/backups/issues/3)) ([660f228](https://github.com/futo-org/backups/commit/660f228afd2590c700625ef97635efb02237d285))

## [1.8.1](https://github.com/futo-org/backups/compare/v1.8.0...v1.8.1) (2026-10-23)


### Bug Fixes

* **yucca-metrics-worker:** publish beta backup count ([#60](https://github.com/futo-org/backups/issues/60)) ([7c5ce9a](https://github.com/futo-org/backups/commit/7c5ce9af2f3a3b73a618ff74dc45d9011e7aaebd))

## [1.8.0](https://github.com/futo-org/backups/compare/v1.7.0...v1.8.0) (2026-10-22)


### Features

* **columbo:** delayed ticket context ([#52](https://github.com/futo-org/backups/issues/52)) ([97179cb](https://github.com/futo-org/backups/commit/97179cb36eb417b722ab9750f64624c08660216b))
* **columbo:** repository source tools ([#47](https://github.com/futo-org/backups/issues/47)) ([f287a9f](https://github.com/futo-org/backups/commit/f287a9fdeeb318acbcfe9feacacfbd97b1ca1da8))
* **futo-backups-bot:** live invite availability ([#50](https://github.com/futo-org/backups/issues/50)) ([fd5229f](https://github.com/futo-org/backups/commit/fd5229f08d230faf33f8ba9fcea16d579200153a))
* **futo-backups-bot:** repeat investigations ([#46](https://github.com/futo-org/backups/issues/46)) ([de5f249](https://github.com/futo-org/backups/commit/de5f2491ba47b3ae675bc9a79d063a4e9c13a518))
* **futo-backups-bot:** ticket version context ([#48](https://github.com/futo-org/backups/issues/48)) ([da23448](https://github.com/futo-org/backups/commit/da23448490cdc297d25145ef33b858583d53ab17))


### Bug Fixes

* **futo-backups-bot:** ticket attachments ([#45](https://github.com/futo-org/backups/issues/45)) ([99ee29c](https://github.com/futo-org/backups/commit/99ee29c91b71ecf82c057eb51f502cf56ae51b3b))
* **yucca-api:** expired invite reservations ([#49](https://github.com/futo-org/backups/issues/49)) ([8fcd554](https://github.com/futo-org/backups/commit/8fcd55433cc5f52ff635fc55c456ebfa3f252e5f))

## [1.7.0](https://github.com/futo-org/backups/compare/v1.6.0...v1.7.0) (2026-10-22)


### Features

* **web:** dark mode ([#42](https://github.com/futo-org/backups/issues/42)) ([bf2bd7f](https://github.com/futo-org/backups/commit/bf2bd7fe3a2f9178b1864e83a31488cd1b327b89))


### Bug Fixes

* **michael:** return 499 when the client cancels a request ([#37](https://github.com/futo-org/backups/issues/37)) ([6d79cde](https://github.com/futo-org/backups/commit/6d79cdea286bae582c55ecfebbe3ba61ea28a7e0))

## [1.6.0](https://github.com/futo-org/backups/compare/v1.5.0...v1.6.0) (2026-10-22)


### Features

* beta details and source link in invite copy ([#31](https://github.com/futo-org/backups/issues/31)) ([0c725e2](https://github.com/futo-org/backups/commit/0c725e21779ebefd5602b095547dbe9cba20c57a))

## [1.5.0](https://github.com/futo-org/backups/compare/v1.4.0...v1.5.0) (2026-10-22)


### Features

* update to node.js 26 ([be544a9](https://github.com/futo-org/backups/commit/be544a931c98e5548f507bf204712648de8e0c92))


### Bug Fixes

* make `@immich/ui` a peer dependency & update to 0.90.0 ([#29](https://github.com/futo-org/backups/issues/29)) ([fbdcd7b](https://github.com/futo-org/backups/commit/fbdcd7b43ba00c8ec88c1b09fd2923d272e5eb3a))
* update to node.js 26 ([#28](https://github.com/futo-org/backups/issues/28)) ([be544a9](https://github.com/futo-org/backups/commit/be544a931c98e5548f507bf204712648de8e0c92))

## [1.4.0](https://github.com/futo-org/backups/compare/v1.3.0...v1.4.0) (2026-10-21)


### Features

* **yucca-metrics-worker:** export beta invite counts ([#24](https://github.com/futo-org/backups/issues/24)) ([40d94b0](https://github.com/futo-org/backups/commit/40d94b090d80e64678a6f0e710286ea99ac45245))

## [1.3.0](https://github.com/futo-org/backups/compare/v1.2.1...v1.3.0) (2026-10-21)


### Features

* **docs:** terms of service and privacy policy ([#20](https://github.com/futo-org/backups/issues/20)) ([b19cf21](https://github.com/futo-org/backups/commit/b19cf217b67f6b74f3c2394a08c7f8a445e7663a))
* **email:** send through resend instead of postmark ([#23](https://github.com/futo-org/backups/issues/23)) ([6628ee2](https://github.com/futo-org/backups/commit/6628ee211af433ccfdb55ddabf1e56120cbc011b))


### Bug Fixes

* **docs:** deploy production to the prod pages branch ([#21](https://github.com/futo-org/backups/issues/21)) ([cae3120](https://github.com/futo-org/backups/commit/cae3120b8fae2fa1a46b8b6e96a03e0f955cf28c))

## [1.2.1](https://github.com/futo-org/backups/compare/v1.2.0...v1.2.1) (2026-10-21)


### Bug Fixes

* **ci:** publish the standalone and restic-proxy images with multi-runner-build v4.1.0 ([#18](https://github.com/futo-org/backups/issues/18)) ([e171227](https://github.com/futo-org/backups/commit/e171227637a23cd15387d8c97812d0bb01c74dab))

## [1.2.0](https://github.com/futo-org/backups/compare/v1.1.0...v1.2.0) (2026-10-21)


### Features

* **emails:** rewrite the beta invite email copy ([#15](https://github.com/futo-org/backups/issues/15)) ([1794a10](https://github.com/futo-org/backups/commit/1794a10de1afe222df19b8293d9d6bfaf96624ab))

## [1.1.0](https://github.com/futo-org/backups/compare/v1.0.0...v1.1.0) (2026-10-21)


### Features

* **yucca sdk:** beta disclaimer notice ([#12](https://github.com/futo-org/backups/issues/12)) ([b223a50](https://github.com/futo-org/backups/commit/b223a5046c6b7bb7bec5997c330992ae35dac7a5))

## [1.0.0](https://github.com/futo-org/backups/compare/v0.55.1...v1.0.0) (2026-10-20)


### Bug Fixes

* **ci:** set the docs deploy environment and stage ([#10](https://github.com/futo-org/backups/issues/10)) ([a384ee9](https://github.com/futo-org/backups/commit/a384ee927f6c35a36d09a6635c847c24cf02ff58))
* **sdk:** reset snapshots on reconfigure ([#843](https://github.com/futo-org/backups/issues/843)) ([dfb3c14](https://github.com/futo-org/backups/commit/dfb3c147fe28c768458ad75b77ab7579ee170ff8))
