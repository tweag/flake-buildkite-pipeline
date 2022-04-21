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
            echo '--- :hammer: Realise the derivation'
            nix build ${escapeShellArg installable} -L -v ${
              concatMapStringsSep " " escapeShellArg buildArgs
            }
          '';

        sign = keys: installable: ''
          echo '--- :black_nib: Sign the paths
          ${map (key:
            "nix store sign -k ${escapeShellArg key} -r ${
              escapeShellArg installable
            }") keys}
        '';

        push = caches: installable: ''
          echo '--- :arrow_up: Push to binary cache'
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
            push = [ "echo '--- :arrow_up: Push to Cachix'" ]
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

        flakeSteps' = { mkBuildCommands, signWithKeys, pushToBinaryCaches
          , buildArgs, systems, commonExtraStepConfig ? { } }:
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
                  } (v.pkg).drvPath;
                  label = v.label;
                  artifact_paths = pkg.value.passthru.artifacts or [ ];
                }) // {
                  __drv = v.pkg;
                } // commonExtraStepConfig) output;

            getCompatibleOutput = name: oldDefaultName:
              (flake.${name} or { })
              // optionalAttrs (flake ? ${oldDefaultName}) {
                default = flake.${oldDefaultName};
              };

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
            }) flake.checks or { };

            devShells = buildOutput ({ name, value }: {
              label = ":nix: Build ${name} development environment${
                  systemMsg " for ${value.system}"
                }";
              pkg = value.inputDerivation;
              signPush = true;
            }) (getCompatibleOutput "devShells" "devShell");

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
            mkBuildCommands = buildSignPush;

            inherit signWithKeys pushToBinaryCaches buildArgs systems
              commonExtraStepConfig;
          };

        flakeStepsCachix = { systems ? [ "x86_64-linux" ], signWithKeys ? [ ]
          , pushToBinaryCaches ? [ ], agents ? [ ], buildArgs ? [ ]
          , commonExtraStepConfig ? { } }:
          flakeSteps' {
            mkBuildCommands = buildPushCachix;
            inherit pushToBinaryCaches signWithKeys buildArgs systems
              commonExtraStepConfig;
          };
      };
    };
}
