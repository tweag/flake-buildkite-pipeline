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

        build = { buildArgs ? [ ] }:
          installable: ''
            echo -- '--- :hammer: Realise the derivation'
            nix build ${escapeShellArg installable} -L -v ${
              concatMapStringsSep " " escapeShellArg buildArgs
            }
          '';

        sign = keys: installable: ''
          echo -- '--- :black_nib: Sign the paths
          ${map (key:
            "nix store sign -k ${escapeShellArg key} -r ${
              escapeShellArg installable
            }") keys}
        '';

        push = caches: installable: ''
          echo -- '--- :arrow_up: Push to binary cache'
          ${map (cache:
            "nix copy --to ${escapeShellArg cache} ${
              escapeShellArg installable
            }") caches}
        '';

        buildSignPush =
          { buildArgs ? [ ], signWithKeys ? [ ], pushToBinaryCaches ? [ ] }:
          installable:
          concatStringsSep "\n" ([ (build { inherit buildArgs; } installable) ]
            ++ optional (signWithKeys != [ ]) (sign signWithKeys installable)
            ++ optional (pushToBinaryCaches != [ ])
            (push pushToBinaryCaches installable));

        buildPushCachix =
          { signWithKeys ? [ ], pushToBinaryCaches ? [ ], buildArgs ? [ ] }:
          installable:
          let
            push = [ "echo -- '--- :arrow_up: Push to Cachix'" ]
              ++ map (cache: "cachix push ${escapeShellArg cache} ./result")
              pushToBinaryCaches;
          in concatStringsSep "\n"
          ([ (build { inherit buildArgs; } installable) ]
            ++ optional (signWithKeys != [ ]) (sign signWithKeys installable)
            ++ optionals (pushToBinaryCaches != [ ]) push);

        runInEnv = environment: command:
          "nix develop ${escapeShellArg environment.drvPath} -c sh -c ${
            escapeShellArg command
          }";

        flakeSteps' = { mkBuildCommands, systems, commonExtraStepConfig ? { } }:
          flake:
          let
            attrsToList = set:
              attrValues (mapAttrs (name: value: { inherit name value; }) set);

            getAttrs' = names: filterAttrs (name: _: elem name names);

            mapOverBuildables = f: buildables:
              map f (concatMap attrsToList
                (attrValues (getAttrs' systems buildables)));

            buildOutput = labelF: pkgF: output:
              mapOverBuildables (pkg:
                ({
                  commands = mkBuildCommands (pkgF pkg.value).drvPath;
                  label = labelF pkg;
                  artifact_paths = pkg.value.passthru.artifacts or [ ];
                }) // {
                  __drv = pkgF pkg.value;
                } // commonExtraStepConfig) output;

            getCompatibleOutput = name: oldDefaultName:
              (flake.${name} or { })
              // optionalAttrs (flake ? ${oldDefaultName}) {
                default = flake.${oldDefaultName};
              };

            systemMsg = optionalString (length systems > 1);

            packages = buildOutput (pkg:
              ":nix: Build ${
                descriptionOrName (pkg.value.meta.description or null) pkg.name
              }${systemMsg " for ${pkg.value.system}"}") id
              (getCompatibleOutput "packages" "defaultPackage");

            checks = buildOutput (check:
              ":nix: Check ${
                descriptionOrName (check.value.meta.checkDescription or null)
                check.name
              }${systemMsg " on ${check.value.system}"}") id
              flake.checks or { };

            devShells = buildOutput (shell:
              ":nix: Build ${shell.name} development environment${
                systemMsg " for ${shell.value.system}"
              }") (pkg: pkg.inputDerivation)
              (getCompatibleOutput "devShells" "devShell");

            # TODO: apps?
            uniqueSteps = uniqListExt {
              inputList = packages ++ checks ++ devShells;
              compare = a: b: a.__drv == b.__drv;
            };
          in map (set: removeAttrs set [ "__drv" ]) uniqueSteps;

        flakeSteps = { systems ? [ "x86_64-linux" ], signWithKeys ? [ ]
          , pushToBinaryCaches ? [ ], agents ? [ ], buildArgs ? [ ]
          , commonExtraStepConfig ? { } }:
          flakeSteps' {
            mkBuildCommands = buildSignPush {
              inherit signWithKeys pushToBinaryCaches buildArgs;
            };
            inherit systems commonExtraStepConfig;
          };

        flakeStepsCachix = { systems ? [ "x86_64-linux" ], signWithKeys ? [ ]
          , pushToBinaryCaches ? [ ], agents ? [ ], buildArgs ? [ ]
          , commonExtraStepConfig ? { } }:
          flakeSteps' {
            mkBuildCommands = buildPushCachix {
              inherit pushToBinaryCaches signWithKeys buildArgs;
            };
            inherit systems commonExtraStepConfig;
          };
      };
    };
}
