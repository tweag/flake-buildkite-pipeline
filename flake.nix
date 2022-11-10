{
  inputs.nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
  outputs = { self, nixpkgs-lib }@inputs:
    let
      inherit (nixpkgs-lib) lib;
      inherit (lib)
        getAttrFromPath collect concatStringsSep mapAttrsRecursiveCond
        optionalAttrs optionalString concatMapStringsSep splitString last head
        optional optionals escapeShellArg isDerivation isAttrs concatLists id
        uniqListExt filterAttrs;
      inherit (builtins)
        concatMap length filter elemAt listToAttrs attrValues mapAttrs elem;
    in {
      lib = let
        descriptionOrName = description: name:
          if isNull description then
            if isNull name then "<unknown>" else name
          else if isNull name then
            description
          else
            "${description} (${name})";
      in rec {
        # [Step] -> JSON
        mkPipeline = steps: builtins.toJSON { inherit steps; };

        build = { buildArgs ? [ ], reproducePath ? null, reproduceRepo ? null
          , derivationCache ? null }:
          installable:
          lib.optional (!isNull derivationCache) ''
            while [ ! -f ${escapeShellArg installable} ]; do
              echo '--- :arrow_down: Copy the missing derivation from cache'
              nix copy --derivation --from ${escapeShellArg derivationCache} ${
                escapeShellArg installable
              } || sleep 5
            done
          '' ++ lib.singleton ''
            echo '--- :hammer: Realise the derivation'
            nix build ${escapeShellArg installable} -L -v ${
              concatMapStringsSep " " escapeShellArg buildArgs
            }
          '' ++ lib.optional (!isNull reproducePath && !isNull reproduceRepo) ''
            echo -e "To reproduce this result, run\n\e[1mgit checkout $BUILDKITE_COMMIT; nix build ${reproduceRepo}#${
              builtins.concatStringsSep "." reproducePath
            }\e[0m"
          '';

        sign = keys: installable:
          [ "echo '--- :black_nib: Sign the paths'" ] ++ map (key:
            "nix store sign -k ${escapeShellArg key} -r ${
              escapeShellArg installable
            }") keys;

        push = caches: installable:
          [ "echo '--- :arrow_up: Push to binary cache'" ] ++ map (cache:
            "nix copy --to ${escapeShellArg cache} ${
              escapeShellArg installable
            }") caches;

        buildSignPush = { buildArgs ? [ ], signWithKeys ? [ ]
          , pushToBinaryCaches ? [ ], reproducePath ? null, reproduceRepo ? null
          , derivationCache ? null }:
          installable:
          concatStringsSep "\n" ((build {
            inherit buildArgs reproducePath reproduceRepo derivationCache;
          } installable)
            ++ optionals (signWithKeys != [ ]) (sign signWithKeys installable)
            ++ optionals (pushToBinaryCaches != [ ])
            (push pushToBinaryCaches installable));

        buildPushCachix = { signWithKeys ? [ ], pushToBinaryCaches ? [ ]
          , buildArgs ? [ ], reproducePath ? null, reproduceRepo ? null
          , derivationCache ? null }:
          installable:
          let
            push = [ "echo '--- :arrow_up: Push to Cachix'" ]
              ++ map (cache: "cachix push ${escapeShellArg cache} ./result")
              pushToBinaryCaches;
          in concatStringsSep "\n" ([
            (build { inherit buildArgs reproducePath reproduceRepo; }
              installable)
          ] ++ optional (signWithKeys != [ ]) (sign signWithKeys installable)
            ++ optionals (pushToBinaryCaches != [ ]) push);

        runInEnv = environment: command:
          "nix develop ${escapeShellArg environment.drvPath} -c sh -c ${
            escapeShellArg command
          }";

        flakeSteps' = { mkBuildCommands, signWithKeys, pushToBinaryCaches
          , buildArgs, systems, commonExtraStepConfig ? { }
          , reproduceRepo ? null, derivationCache ? null }:
          flake:
          let
            attrsToList = set:
              attrValues (mapAttrs (name: value: { inherit name value; }) set);

            getAttrs' = names: filterAttrs (name: _: elem name names);

            mapOverBuildables = f: buildables:
              map f (concatMap attrsToList
                (attrValues (getAttrs' systems buildables)));

            buildOutput = f: output:
              mapOverBuildables (pkg:
                let v = f pkg;
                in ({
                  commands = mkBuildCommands {
                    signWithKeys = if v.signPush then signWithKeys else [ ];
                    pushToBinaryCaches =
                      if v.signPush then pushToBinaryCaches else [ ];
                    inherit buildArgs;
                    reproducePath = v.pkg.meta.reproducePath or null;
                    inherit reproduceRepo derivationCache;
                  } (v.pkg).drvPath;
                  label = v.label;
                  artifact_paths = pkg.value.passthru.artifacts or [ ];
                  key = builtins.concatStringsSep "_"
                    v.pkg.meta.reproducePath or [ v.pkg.name ];
                }) // {
                  __drv = v.pkg;
                } // commonExtraStepConfig) output;

            injectAttrPath = ap:
              mapAttrs (system:
                mapAttrs (name: value:
                  lib.recursiveUpdate value {
                    meta.reproducePath = ap ++ [ system name ];
                  }));

            getCompatibleOutput = name: oldDefaultName:
              lib.recursiveUpdate
              (injectAttrPath [ name ] (flake.${name} or { })) (mapAttrs
                (system: pkg: {
                  default = lib.recursiveUpdate pkg {
                    meta.reproducePath = [ oldDefaultName system ];
                  };
                }) (flake.${oldDefaultName} or { }));

            systemMsg = optionalString (length systems > 1);

            packages = buildOutput ({ name, value }: {
              label = ":nix: Build ${
                  descriptionOrName (value.meta.description or null)
                  (if name == "default" then value.name else name)
                }${systemMsg " for ${value.system}"}";
              pkg = value;
              signPush = value.passthru.cache or true;
            }) (getCompatibleOutput "packages" "defaultPackage");

            checks = buildOutput ({ name, value }: {
              label = ":nix: Check ${
                  descriptionOrName (value.meta.checkDescription or null) name
                }${systemMsg " on ${value.system}"}";
              pkg = value;
              signPush = false;
            }) (injectAttrPath [ "checks" ] flake.checks or { });

            devShells = buildOutput ({ name, value }: {
              label = ":nix: Build ${name} development environment${
                  systemMsg " for ${value.system}"
                }";
              pkg = value.inputDerivation // { inherit (value) meta; };
              signPush = true;
            }) (getCompatibleOutput "devShells" "devShell");

            # TODO: apps?
            uniqueSteps = uniqListExt {
              inputList = packages ++ checks ++ devShells;
              compare = a: b: a.__drv == b.__drv;
            };
          in map (set: removeAttrs set [ "__drv" ]) uniqueSteps;

        flakeSteps = { systems ? [ "x86_64-linux" ], reproduceRepo ? null
          , signWithKeys ? [ ], pushToBinaryCaches ? [ ], agents ? [ ]
          , buildArgs ? [ ], commonExtraStepConfig ? { }, derivationCache ? null
          }:
          flakeSteps' {
            mkBuildCommands = buildSignPush;

            inherit reproduceRepo signWithKeys pushToBinaryCaches buildArgs
              systems commonExtraStepConfig derivationCache;
          };

        flakeStepsCachix = { systems ? [ "x86_64-linux" ], reproduceRepo ? "."
          , signWithKeys ? [ ], pushToBinaryCaches ? [ ], agents ? [ ]
          , buildArgs ? [ ], commonExtraStepConfig ? { } }:
          flakeSteps' {
            mkBuildCommands = buildPushCachix;
            inherit reproduceRepo pushToBinaryCaches signWithKeys buildArgs
              systems commonExtraStepConfig;
          };

        uploadPipeline = pipeline:
          { derivationCache ? null }:
          "buildkite-agent pipeline upload <<< ${
            lib.escapeShellArg (__toJSON pipeline)
          }${
            lib.optionalString (!isNull derivationCache)
            " | nix copy --to ${lib.escapeShellArg derivationCache} ${
               lib.escapeShellArgs
               (__attrNames (__getContext (__toJSON pipeline)))
             }"
          }";
      };
    };
}
