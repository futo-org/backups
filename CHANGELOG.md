# Changelog

## [1.24.0](https://github.com/futo-org/backups/compare/v1.23.0...v1.24.0) (2026-11-26)


### Features

* **yucca-api:** reusable named invite codes with use limits and metrics ([#367](https://github.com/futo-org/backups/issues/367)) ([e9df016](https://github.com/futo-org/backups/commit/e9df01639131978ac44549fc2d8dd79bf656ea00))

## [1.23.0](https://github.com/futo-org/backups/compare/v1.22.0...v1.23.0) (2026-11-26)


### Features

* **common:** add windows connection type ([#365](https://github.com/futo-org/backups/issues/365)) ([76c22ff](https://github.com/futo-org/backups/commit/76c22ff04a843f96a68a363ea3047f6dba75902c))
* **macos-app:** keep the Mac awake during backups and let scheduled backups wait for power, Ethernet or a dock ([#363](https://github.com/futo-org/backups/issues/363)) ([262ad6a](https://github.com/futo-org/backups/commit/262ad6ad25aac8e29424ed00fcdffe8c3ba1c031))
* **macos-app:** list exclusions in a searchable sheet ([#362](https://github.com/futo-org/backups/issues/362)) ([38f0183](https://github.com/futo-org/backups/commit/38f0183a82a56669c04b5c0a06c4220390f2132b))

## [1.22.0](https://github.com/futo-org/backups/compare/v1.21.0...v1.22.0) (2026-11-25)


### Features

* **macos-app:** add Back Up Now to the toolbar outside Overview and to the Dock menu ([#347](https://github.com/futo-org/backups/issues/347)) ([34e70ad](https://github.com/futo-org/backups/commit/34e70adf80e2275fa889d775104ea113af3d5db8))
* **macos-app:** apply HIG quick wins to menus, keyboard, text and accessibility ([#348](https://github.com/futo-org/backups/issues/348)) ([05a954a](https://github.com/futo-org/backups/commit/05a954a08ef907a8a9a88397cc510932d526b7b9))
* **macos-app:** ask for Touch ID or the Mac password before revealing or changing the recovery key ([#341](https://github.com/futo-org/backups/issues/341)) ([fc936b4](https://github.com/futo-org/backups/commit/fc936b4d35e09bed2698cfc7859d67776d00ffa4))
* **macos-app:** follow the system accent in the sidebar, tuck parallelism under Advanced and honor Increase Contrast ([#350](https://github.com/futo-org/backups/issues/350)) ([4e232dc](https://github.com/futo-org/backups/commit/4e232dc5c13ce67b30c6e54acfb52a1ef3e31b94))
* **macos-app:** notify once when a scheduled backup fails ([#351](https://github.com/futo-org/backups/issues/351)) ([749e51b](https://github.com/futo-org/backups/commit/749e51bdb65a2c7f5f95474f45cfa88df1a39765))
* **macos-app:** offer the onboarding folder presets when no folders are selected ([#343](https://github.com/futo-org/backups/issues/343)) ([42b5138](https://github.com/futo-org/backups/commit/42b5138fbd2883da1a4082b2bf1b4a076be220bb))
* **macos-app:** pick a Mac backup first, then check its recovery key ([#339](https://github.com/futo-org/backups/issues/339)) ([62cacbd](https://github.com/futo-org/backups/commit/62cacbd40acff5feed32da728e069d098679df2c))
* **macos-app:** show the total size of the selected folders while choosing them in onboarding ([#344](https://github.com/futo-org/backups/issues/344)) ([aa829d1](https://github.com/futo-org/backups/commit/aa829d1cce48f91005499a208780388a77cbe68c))
* **macos-app:** use native window titles and toolbar actions for each page ([#345](https://github.com/futo-org/backups/issues/345)) ([08157dd](https://github.com/futo-org/backups/commit/08157dd4b245238aaeda83c86f9bd42c3929e606))


### Bug Fixes

* **docs:** jump to content after hydration ([#354](https://github.com/futo-org/backups/issues/354)) ([e609a25](https://github.com/futo-org/backups/commit/e609a25a7e91581cd62829331aba59c99e3fceab))
* **macos-app:** drop the sent total from the upload speed card ([#342](https://github.com/futo-org/backups/issues/342)) ([9e2504c](https://github.com/futo-org/backups/commit/9e2504c5d6f943f6039fd75e696a0ce18d308538))
* **macos-app:** show friendly network errors and retry transient discovery failures ([#358](https://github.com/futo-org/backups/issues/358)) ([498a594](https://github.com/futo-org/backups/commit/498a5946ce0f00621b1f1104b44dac69c45b4216))
* **macos-app:** stack the menu bar panel's open, update and quit actions as full-width rows ([#346](https://github.com/futo-org/backups/issues/346)) ([8544508](https://github.com/futo-org/backups/commit/8544508142a986216e83fa0fc2c5235cf91d335e))
* **macos-app:** use the contrast-safe fill for the toolbar Back Up Now ([#356](https://github.com/futo-org/backups/issues/356)) ([d647610](https://github.com/futo-org/backups/commit/d647610aa64b4c0e55516096d0417c5063ce0d23))
* **michael:** move per-user request labels to client.request.count ([#359](https://github.com/futo-org/backups/issues/359)) ([fe4df7b](https://github.com/futo-org/backups/commit/fe4df7b60e4aee1d23bae3373459d4a1c27a121e))
* **yucca sdk:** gracefully fallback w. invalid TZ ([#353](https://github.com/futo-org/backups/issues/353)) ([acbd088](https://github.com/futo-org/backups/commit/acbd0880ba31a32730b9171785adc34b26b8a96c))


### Code Refactoring

* **macos-app:** rewrite app text in plain English ([#361](https://github.com/futo-org/backups/issues/361)) ([9020c52](https://github.com/futo-org/backups/commit/9020c527f965ac6fb6524f85aa404550fbaa6728))
* **macos-app:** use system button styles tinted with the brand indigo ([#349](https://github.com/futo-org/backups/issues/349)) ([51914c7](https://github.com/futo-org/backups/commit/51914c7b71f36e027a95cba5d049d79f3d30727a))


### Documentation

* add a Mac app setup page ([#360](https://github.com/futo-org/backups/issues/360)) ([4024bf2](https://github.com/futo-org/backups/commit/4024bf2ad9344607761d932f5c420702b9689cbe))


### Tests

* **macos-app:** give the disk snapshot timeout tests room on busy runners ([#357](https://github.com/futo-org/backups/issues/357)) ([b34f127](https://github.com/futo-org/backups/commit/b34f1275b2d6c34fb1869c2be97e40f1ee4d59e5))
* **macos-app:** run the cloud-only scan at normal priority in engine tests ([#355](https://github.com/futo-org/backups/issues/355)) ([a1e766a](https://github.com/futo-org/backups/commit/a1e766a28e6668daeb80ed6293200ee4b5830efd))

## [1.21.0](https://github.com/futo-org/backups/compare/v1.20.1...v1.21.0) (2026-11-24)


### Features

* **macos-app:** browse a snapshot and restore individual files and folders ([#332](https://github.com/futo-org/backups/issues/332)) ([c9e92ac](https://github.com/futo-org/backups/commit/c9e92acfd7c3bf5fad0bf4e1e7104a19bb753ee8))
* **macos-app:** configurable snapshot retention ([#319](https://github.com/futo-org/backups/issues/319)) ([8972a54](https://github.com/futo-org/backups/commit/8972a549fc84b12b9d7570129441fde1005eeb2b))
* **macos-app:** keep running in the menu bar when the window is closed or the app is quit ([#321](https://github.com/futo-org/backups/issues/321)) ([eae14db](https://github.com/futo-org/backups/commit/eae14db6a6113e7253d340d116965ccdb73b4103))
* **macos-app:** require macOS 26 so the app gets the current native controls ([4740842](https://github.com/futo-org/backups/commit/474084212d037277fd95740e769f356c73c9bc35))
* **macos-app:** show every file a backup with warnings skipped ([#314](https://github.com/futo-org/backups/issues/314)) ([d4d63f1](https://github.com/futo-org/backups/commit/d4d63f1527cea862ff49c7019bfec345cb3f1a27))
* **macos-app:** show restore progress with percent, bytes and items ([#334](https://github.com/futo-org/backups/issues/334)) ([682d5e8](https://github.com/futo-org/backups/commit/682d5e8e3081e5106951074aa292c92c329c86ee))
* **macos-app:** turn on open at login and update checks during onboarding ([#313](https://github.com/futo-org/backups/issues/313)) ([e257f43](https://github.com/futo-org/backups/commit/e257f43271c81f300cb77fb46256e366c5726682))
* **yucca-api:** report unsupported connection types in the device flow ([#304](https://github.com/futo-org/backups/issues/304)) ([08d2599](https://github.com/futo-org/backups/commit/08d25996116e98fc42bfad1f5bcd88a0d84da914))


### Bug Fixes

* **macos-app:** center setting controls next to two-line labels ([#330](https://github.com/futo-org/backups/issues/330)) ([169211f](https://github.com/futo-org/backups/commit/169211f3010b479583fdc9bbb6760663664bb258))
* **macos-app:** harden restore ([#337](https://github.com/futo-org/backups/issues/337)) ([1fb30dd](https://github.com/futo-org/backups/commit/1fb30dd9a23efc4ff0041e2c041112f9bb80e252))
* **macos-app:** keep each server's backup and offer existing ones instead of creating a new one ([#322](https://github.com/futo-org/backups/issues/322)) ([441f8ca](https://github.com/futo-org/backups/commit/441f8cae7dbdcbf30bb5213a30b9441774366fdc))
* **macos-app:** keep the night hours row inside the settings form ([#324](https://github.com/futo-org/backups/issues/324)) ([982ec4b](https://github.com/futo-org/backups/commit/982ec4b0f146da224f12b002c0356ad4a5c2517c))
* **macos-app:** lay out folder cards in two columns at every width ([#326](https://github.com/futo-org/backups/issues/326)) ([0fd89b7](https://github.com/futo-org/backups/commit/0fd89b7b20f7557602aa4a1aca0f0ab651d53446))
* **macos-app:** let dev builds auto-update to the next release ([#315](https://github.com/futo-org/backups/issues/315)) ([788e1ad](https://github.com/futo-org/backups/commit/788e1ad0400672ff69e0e62af3e2bf7a8019e1ad))
* **macos-app:** recover from network switches and cancel backups promptly ([#316](https://github.com/futo-org/backups/issues/316)) ([ed80e59](https://github.com/futo-org/backups/commit/ed80e59c88a0631cdb26a22bbb6fd0d8019f46eb))
* **macos-app:** rename "Reset This Mac" to "Unlink This Mac" ([#325](https://github.com/futo-org/backups/issues/325)) ([ea11517](https://github.com/futo-org/backups/commit/ea115175a29515687e4cd4febf5ac8da1f0a34b3))
* **macos-app:** reword the unlink and delete backup sheets in plain language ([#333](https://github.com/futo-org/backups/issues/333)) ([aaea170](https://github.com/futo-org/backups/commit/aaea17017cdd2e94d715efbfdf8d1726121dd678))
* **macos-app:** save the recovery key on a single line ([#323](https://github.com/futo-org/backups/issues/323)) ([2629ad7](https://github.com/futo-org/backups/commit/2629ad7ccd4fdbd5ecfdacbd26029c9a885cd51e))
* **macos-app:** shorten the restore destination prompt ([#328](https://github.com/futo-org/backups/issues/328)) ([04a83bd](https://github.com/futo-org/backups/commit/04a83bd9a303a6966dedc62c6d5004cf399dfb66))
* **macos-app:** use a native field for the upload limit and align setting text fields ([#335](https://github.com/futo-org/backups/issues/335)) ([dd8046f](https://github.com/futo-org/backups/commit/dd8046fad2218434e51f901aa6bbb46f373af6a6))
* **restic-proxy:** fail aborted uploads promptly between body reads ([#329](https://github.com/futo-org/backups/issues/329)) ([7b91ec4](https://github.com/futo-org/backups/commit/7b91ec4f6a21e5dbc81f7560838879a873eb0d41))


### Performance Improvements

* **macos-app:** stop backup progress from redrawing the whole window ([#317](https://github.com/futo-org/backups/issues/317)) ([a6b4981](https://github.com/futo-org/backups/commit/a6b4981f33a70184b05ddfc4a9964aa8befc29dd))


### Tests

* **macos-app:** give the cancelled cloud-only scan time to notice on busy runners ([#336](https://github.com/futo-org/backups/issues/336)) ([2375e55](https://github.com/futo-org/backups/commit/2375e5511f098f5e18a7c866c0e4eaf1e26144ac))
* **restic-proxy:** check progress coalescing by when the latest total arrives ([#331](https://github.com/futo-org/backups/issues/331)) ([ff8b927](https://github.com/futo-org/backups/commit/ff8b927cc3f58ccc85d64229e87c6f79e9d2b7bc))
* **yucca-api:** cover unsupported connection type in the device poll response ([#320](https://github.com/futo-org/backups/issues/320)) ([24058ba](https://github.com/futo-org/backups/commit/24058bae3919de9c58428358743b955c0deca553))

## [1.20.1](https://github.com/futo-org/backups/compare/v1.20.0...v1.20.1) (2026-11-24)


### Bug Fixes

* **ci:** create Mac releases with the release bot token ([#309](https://github.com/futo-org/backups/issues/309)) ([74b0426](https://github.com/futo-org/backups/commit/74b0426704025062a77470901004bcccda21c338))
* **ci:** request workflows access for the Mac release tag ([#312](https://github.com/futo-org/backups/issues/312)) ([c3a8daf](https://github.com/futo-org/backups/commit/c3a8daf87a754bbbb6b04237d2429c59128f5d9b))
* **macos-app:** remove server selection from release builds ([#311](https://github.com/futo-org/backups/issues/311)) ([71b0b5c](https://github.com/futo-org/backups/commit/71b0b5cd866b6562cfae4796e6a6c8aed4a1d4b4))

## [1.20.0](https://github.com/futo-org/backups/compare/v1.19.0...v1.20.0) (2026-11-24)


### Features

* **macos-app:** native macOS backup app ([#296](https://github.com/futo-org/backups/issues/296)) ([185aea4](https://github.com/futo-org/backups/commit/185aea4c4dc3a93742e53742abcaa2c708f8bb8e))

## [1.19.0](https://github.com/futo-org/backups/compare/v1.18.1...v1.19.0) (2026-11-24)


### Features

* **common:** add macos connection type ([#300](https://github.com/futo-org/backups/issues/300)) ([4eaed0e](https://github.com/futo-org/backups/commit/4eaed0eac87ae8261c502b3c49fd798e5f328aca))


### Bug Fixes

* **docs:** clarify that beta telemetry stops when backups are turned off ([#294](https://github.com/futo-org/backups/issues/294)) ([9071557](https://github.com/futo-org/backups/commit/90715579b887a7fc22554b31137e27edd0b185a7))

## [1.18.1](https://github.com/futo-org/backups/compare/v1.18.0...v1.18.1) (2026-11-17)


### Bug Fixes

* **yucca sdk:** skip the leader unlock if connection was dropped ([#289](https://github.com/futo-org/backups/issues/289)) ([497fcc0](https://github.com/futo-org/backups/commit/497fcc02b55fa71f89dfc4d7b8ab461a9e23725f))

## [1.18.0](https://github.com/futo-org/backups/compare/v1.17.0...v1.18.0) (2026-11-17)


### Features

* **web:** link to account and security settings in the dashboard header ([#282](https://github.com/futo-org/backups/issues/282)) ([7a22292](https://github.com/futo-org/backups/commit/7a22292a03288ec2b62ed0599b95eb4528617c2a))
* **yucca sdk:** cache repository names locally ([#227](https://github.com/futo-org/backups/issues/227)) ([40be1ed](https://github.com/futo-org/backups/commit/40be1ed5683d21019068679ca3edbb313498b79b))
* **yucca sdk:** deterministic default schedules based on installation id ([#218](https://github.com/futo-org/backups/issues/218)) ([ce7c0a8](https://github.com/futo-org/backups/commit/ce7c0a815e4762c9f9ac0c648adb32476a5fa1ad))
* **yucca sdk:** gate the Immich database backup alert behind a feature flag ([#219](https://github.com/futo-org/backups/issues/219)) ([39e1250](https://github.com/futo-org/backups/commit/39e12505db4067ce162b70016691150d67cb3b7a))
* **yucca sdk:** preview custom run times ([#288](https://github.com/futo-org/backups/issues/288)) ([a10ca90](https://github.com/futo-org/backups/commit/a10ca902421701641c73172882f9a58c121ced67))
* **yucca sdk:** record skipped scheduled backups in metrics history ([#287](https://github.com/futo-org/backups/issues/287)) ([0360677](https://github.com/futo-org/backups/commit/036067723b2576fab3b33976a0f0259fc0ce1b26))
* **yucca sdk:** show next backup time in setup modal ([#286](https://github.com/futo-org/backups/issues/286)) ([bd19fdf](https://github.com/futo-org/backups/commit/bd19fdfd8794213869467418ff46836a12185ff5))
* **yucca sdk:** show the scheduler time zone alongside schedule times ([#284](https://github.com/futo-org/backups/issues/284)) ([e0010c1](https://github.com/futo-org/backups/commit/e0010c14d30c3964a3a96763185649a53db9745a))


### Bug Fixes

* **orchestration-ui:** clearer snapshot menu labels for roll back and restore ([#213](https://github.com/futo-org/backups/issues/213)) ([5951e96](https://github.com/futo-org/backups/commit/5951e96e09841393cd392374a4ffcbae4185c08e))
* **yucca sdk:** always show active backup on Immich status card ([#279](https://github.com/futo-org/backups/issues/279)) ([83becff](https://github.com/futo-org/backups/commit/83becffdb22a150ed62a4c1f4289d8d258afe3bf))
* **yucca sdk:** apply Immich library exclusion patterns to backups ([#226](https://github.com/futo-org/backups/issues/226)) ([38496bc](https://github.com/futo-org/backups/commit/38496bcd623407bfa6b26429d7d4880016726698))
* **yucca sdk:** change cancel confirm dialog text ([#275](https://github.com/futo-org/backups/issues/275)) ([bda7d5e](https://github.com/futo-org/backups/commit/bda7d5ecd4ea8c64b27c0f63ee6bd6beee1ed215))
* **yucca sdk:** keep the leader lock on its own connection ([#281](https://github.com/futo-org/backups/issues/281)) ([31ccd27](https://github.com/futo-org/backups/commit/31ccd276692f591952c1103ea716bccbe9a8853b))
* **yucca sdk:** make 'X' skip starting a backup ([#276](https://github.com/futo-org/backups/issues/276)) ([71d4d8a](https://github.com/futo-org/backups/commit/71d4d8a4be71a68f1765d06a79453afd371e8b53))
* **yucca sdk:** skip scheduled backups for repositories with running/q'd backup ([#278](https://github.com/futo-org/backups/issues/278)) ([c031fc4](https://github.com/futo-org/backups/commit/c031fc425c35875b567300f0be5f3ebe7119fd8d))
* **yucca sdk:** use the same schedule description everywhere ([#283](https://github.com/futo-org/backups/issues/283)) ([9c3bc1c](https://github.com/futo-org/backups/commit/9c3bc1c70a54fc57aa617c8a90a20662316a995a))


### Documentation

* **legal:** cover support and Discord ticket data in the privacy policy ([#220](https://github.com/futo-org/backups/issues/220)) ([fa2578b](https://github.com/futo-org/backups/commit/fa2578b80d8cfd994a0f440ee9eae97c147fa683))

## [1.17.0](https://github.com/futo-org/backups/compare/v1.16.0...v1.17.0) (2026-11-12)


### Features

* **michael:** spread gateways evenly across nodes ([#207](https://github.com/futo-org/backups/issues/207)) ([ee47fcf](https://github.com/futo-org/backups/commit/ee47fcf8ab48d3fc26870887e6e5cd84ec70c412))

## [1.16.0](https://github.com/futo-org/backups/compare/v1.15.0...v1.16.0) (2026-11-11)


### Features

* **yucca sdk:** expose the restic connections override in bandwidth settings ([#200](https://github.com/futo-org/backups/issues/200)) ([c105f16](https://github.com/futo-org/backups/commit/c105f16441e9db3675eeb6be760c2d1781c666a0))


### Bug Fixes

* **yucca sdk:** clarify the Immich database backup alert ([#205](https://github.com/futo-org/backups/issues/205)) ([43f4f90](https://github.com/futo-org/backups/commit/43f4f9016b0528cefc76a92498b9551e94ba1140))
* **yucca sdk:** explain clearly when the restic binary is missing ([#201](https://github.com/futo-org/backups/issues/201)) ([7cc89dd](https://github.com/futo-org/backups/commit/7cc89dde6389c4dbf4bbff073db5f3b938fcc87b))
* **yucca sdk:** say clearly that the recovery key is one key ([#204](https://github.com/futo-org/backups/issues/204)) ([60733bc](https://github.com/futo-org/backups/commit/60733bc7aed161137a9c7b59347517229d02d240))


### Documentation

* add an FAQ page ([#192](https://github.com/futo-org/backups/issues/192)) ([8256ca9](https://github.com/futo-org/backups/commit/8256ca9c90e557a2776ea7a71ad659070803777c))


### Tests

* fix broken test ([#197](https://github.com/futo-org/backups/issues/197)) ([6254bd9](https://github.com/futo-org/backups/commit/6254bd9b1f19314a7f560b6e0e8c0b3a17984e6a))

## [1.15.0](https://github.com/futo-org/backups/compare/v1.14.0...v1.15.0) (2026-11-10)


### Features

* **standalone:** show the app version in the header ([#177](https://github.com/futo-org/backups/issues/177)) ([12174de](https://github.com/futo-org/backups/commit/12174de4f4d0c94a6db94df6f0c66e6aa8491fcf))


### Bug Fixes

* **standalone:** ship a multi-size favicon and apple-touch-icon ([#181](https://github.com/futo-org/backups/issues/181)) ([f00afe5](https://github.com/futo-org/backups/commit/f00afe529a84e5ea6ee073a13ec419d2cc06e50d))
* **yucca sdk:** drop Immich from str shared with the standalone ([#180](https://github.com/futo-org/backups/issues/180)) ([7c1e2de](https://github.com/futo-org/backups/commit/7c1e2de24bb34101b3dcfe573daa586bdf01e90a))
* **yucca sdk:** let the deleting snapshot toast be dismissed ([#178](https://github.com/futo-org/backups/issues/178)) ([30f4f73](https://github.com/futo-org/backups/commit/30f4f73bd4453ca84979c119726aa9af1b5f3a84))
* **yucca sdk:** only explain connectivity for failed jobs, not ones that finished with warnings ([#176](https://github.com/futo-org/backups/issues/176)) ([88c803d](https://github.com/futo-org/backups/commit/88c803d104d5f408761abbc583d739776cb3fb48))
* **yucca sdk:** skip empty local metrics upsert when stats fails ([#175](https://github.com/futo-org/backups/issues/175)) ([9adaf71](https://github.com/futo-org/backups/commit/9adaf71b95cb8be87eb21ea0e1c3348cc1acf16f))


### Documentation

* point Immich setup copy at the v3.4.0 release ([#191](https://github.com/futo-org/backups/issues/191)) ([d899068](https://github.com/futo-org/backups/commit/d899068935963a22bc0657472fa07884ffcbb0b0))


### Miscellaneous Chores

* **npm:** update dependency @vitest/browser (5.0.3 → 5.0.5) [security] ([#77](https://github.com/futo-org/backups/issues/77)) ([3198a25](https://github.com/futo-org/backups/commit/3198a25e184573d7c72e52a66bb8b9070176accd))
* **npm:** update dependency vite (8.3.2 → 8.3.3) [security] ([#79](https://github.com/futo-org/backups/issues/79)) ([8c04e4b](https://github.com/futo-org/backups/commit/8c04e4bf8e257df263d3d78e09e3b4602437502d))

## [1.14.0](https://github.com/futo-org/backups/compare/v1.13.1...v1.14.0) (2026-11-09)


### Features

* **api:** polling-style device code flow ([#186](https://github.com/futo-org/backups/issues/186)) ([7c9b288](https://github.com/futo-org/backups/commit/7c9b2884f540bc9867c363d39050b0544a3b3137))
* **yucca sdk:** poll device login ([#187](https://github.com/futo-org/backups/issues/187)) ([8146c49](https://github.com/futo-org/backups/commit/8146c49d27a52ac42a51a5cb8f89ba9ee9bf0aa8))

## [1.13.1](https://github.com/futo-org/backups/compare/v1.13.0...v1.13.1) (2026-11-06)


### Bug Fixes

* **yucca sdk:** skip the session guard when the host does not require sessions ([#183](https://github.com/futo-org/backups/issues/183)) ([824e1bb](https://github.com/futo-org/backups/commit/824e1bb3b722492624f2e0e84ebafea68ce071bd))
* **yucca sdk:** truncate tables on dev reset instead of dropping types ([#182](https://github.com/futo-org/backups/issues/182)) ([60bee40](https://github.com/futo-org/backups/commit/60bee409ff59d8306100ef1094805d296288b9bc))

## [1.13.0](https://github.com/futo-org/backups/compare/v1.12.1...v1.13.0) (2026-11-06)


### Features

* **futo-backups-bot:** turn on support mode from a ticket until it closes ([#162](https://github.com/futo-org/backups/issues/162)) ([925cd93](https://github.com/futo-org/backups/commit/925cd93df834b66e1f9aee4616ba80b6a3705894))
* **yucca sdk:** swap SQLite for Postgres ([#137](https://github.com/futo-org/backups/issues/137)) ([1b24c5f](https://github.com/futo-org/backups/commit/1b24c5fafdce1de15e1fb4283da38a02d973cc91))


### Bug Fixes

* **docs:** use the FUTO Backups icon for docs.futo.cloud ([#171](https://github.com/futo-org/backups/issues/171)) ([5297b51](https://github.com/futo-org/backups/commit/5297b518a8d4e2ef12966cfdb6d76f11c975c138))
* **orchestration-ui:** don't show "Yucca Server Error" for client-side fetch failures ([#159](https://github.com/futo-org/backups/issues/159)) ([bc3c566](https://github.com/futo-org/backups/commit/bc3c5663453747ac995b0b1b9933052f986f58f9))
* **orchestration-ui:** unambiguous backup ETA (M for months, max three units) ([#174](https://github.com/futo-org/backups/issues/174)) ([c69fcb7](https://github.com/futo-org/backups/commit/c69fcb7da12e28f463c8ff82df711289cb4cb846))
* **yucca-api:** fall back to given and family name when the name claim is missing ([#160](https://github.com/futo-org/backups/issues/160)) ([1dd0776](https://github.com/futo-org/backups/commit/1dd0776f37d2e4423d3b9e252a74be63883a381a))


### Miscellaneous Chores

* remove git-town ([#170](https://github.com/futo-org/backups/issues/170)) ([7d191c2](https://github.com/futo-org/backups/commit/7d191c2cccbea12ccf47111bdc727b5457a2f555))

## [1.12.1](https://github.com/futo-org/backups/compare/v1.12.0...v1.12.1) (2026-10-30)


### Bug Fixes

* **yucca sdk:** reattach the restore flow to an in-progress restore ([#118](https://github.com/futo-org/backups/issues/118)) ([a9cc691](https://github.com/futo-org/backups/commit/a9cc6918fe4e72a55701abe01db1494136af78c0))

## [1.12.0](https://github.com/futo-org/backups/compare/v1.11.5...v1.12.0) (2026-10-30)


### Features

* **web:** onboarding checklist and backup info on the dashboard overview ([#133](https://github.com/futo-org/backups/issues/133)) ([2722ba0](https://github.com/futo-org/backups/commit/2722ba02ad5fe88ee199626b89ae86e0f62a071c))
* **yucca sdk:** probe docs.futo.cloud on connectivity failures to tell the user's network from our outage ([#124](https://github.com/futo-org/backups/issues/124)) ([6fe2937](https://github.com/futo-org/backups/commit/6fe2937c15e2290f4fa57c4c069896a0ee46fb47))
* **yucca sdk:** skip restic's scan on parallel incrementals and estimate progress from the previous backup ([#143](https://github.com/futo-org/backups/issues/143)) ([ccc8bdd](https://github.com/futo-org/backups/commit/ccc8bdd9b8bc3c5d71ae3c7d2e5aaaf0f59746d0))
* **yucca sdk:** walk 64 directory entries at a time with futo's restic ([#142](https://github.com/futo-org/backups/issues/142)) ([e2a3637](https://github.com/futo-org/backups/commit/e2a3637bf6f91abf4c18e02fce5d371ca6109b98))


### Bug Fixes

* **e2e:** stop the k3d e2e cleanup from killing its own process group ([#136](https://github.com/futo-org/backups/issues/136)) ([4720c82](https://github.com/futo-org/backups/commit/4720c82ceed70e7702af89b197eae35aca3d6585))
* **yucca sdk:** ship support status, summary and error lines ahead of per-file lines ([#140](https://github.com/futo-org/backups/issues/140)) ([0a3d3b8](https://github.com/futo-org/backups/commit/0a3d3b83b717fa51352c29baca95f72150673ea9))


### Miscellaneous Chores

* **standalone-app:** ship restic with the parallel scan ([#141](https://github.com/futo-org/backups/issues/141)) ([e66332d](https://github.com/futo-org/backups/commit/e66332d7d0d1abbb3d1247887e94d00c14fdc66d))
* use futo's restic build in dev and ci ([#144](https://github.com/futo-org/backups/issues/144)) ([19a7a96](https://github.com/futo-org/backups/commit/19a7a96ca2bff5caa57f4676a10de5533ab63150))

## [1.11.5](https://github.com/futo-org/backups/compare/v1.11.4...v1.11.5) (2026-10-29)


### Code Refactoring

* **yucca sdk:** prefix all operation IDs with `futoBackups` ([#132](https://github.com/futo-org/backups/issues/132)) ([8cb37ab](https://github.com/futo-org/backups/commit/8cb37abbf29c8773db27603d7c77851802c78109))

## [1.11.4](https://github.com/futo-org/backups/compare/v1.11.3...v1.11.4) (2026-10-29)


### Code Refactoring

* **yucca sdk:** let consumers provide their own layout ([#126](https://github.com/futo-org/backups/issues/126)) ([92c0e1a](https://github.com/futo-org/backups/commit/92c0e1a07793483463f23e24411e0c8c67a626d1))
* **yucca sdk:** move routes under `/api/futo-backups` ([#125](https://github.com/futo-org/backups/issues/125)) ([7a40dd9](https://github.com/futo-org/backups/commit/7a40dd99619d633f3f45850a7fa7f7c7c4efac68))
* **yucca sdk:** wrap lingui for consumers ([#127](https://github.com/futo-org/backups/issues/127)) ([87888ac](https://github.com/futo-org/backups/commit/87888ac969ea40db36718ad64cba830a8b6cd446))


### Miscellaneous Chores

* include refactors in releases ([#129](https://github.com/futo-org/backups/issues/129)) ([133cc09](https://github.com/futo-org/backups/commit/133cc09cf43b9dac57d7ea187f11488e5a2a93ef))
* release all types ([#131](https://github.com/futo-org/backups/issues/131)) ([1025341](https://github.com/futo-org/backups/commit/1025341e268e1df6b10bbd26001fdd232968dfda))

## [1.11.3](https://github.com/futo-org/backups/compare/v1.11.2...v1.11.3) (2026-10-28)


### Bug Fixes

* **yucca sdk:** keep several support log batches in flight so fast output isn't dropped ([#119](https://github.com/futo-org/backups/issues/119)) ([a73d543](https://github.com/futo-org/backups/commit/a73d54382904f185e8220ed768dc882ee9bf550a))

## [1.11.2](https://github.com/futo-org/backups/compare/v1.11.1...v1.11.2) (2026-10-28)


### Bug Fixes

* **yucca sdk:** give every OpenAPI number a format so hosts can merge the document ([#110](https://github.com/futo-org/backups/issues/110)) ([5624c3b](https://github.com/futo-org/backups/commit/5624c3b793ef0e0add61adf6973536116bc5f544))

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
