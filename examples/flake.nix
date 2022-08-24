{
  description = "flake-buildkite-pipeline example";

  inputs.flake-buildkite-pipeline.url = "github:tweag/flake-buildkite-pipeline";

  outputs = { self, nixpkgs, flake-buildkite-pipeline }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.hello = pkgs.hello;

      checks.${system} = let
        mkHelloCheck = { checkName, traditional ? false, greeting ? "" }:
          let
            inherit (pkgs.lib.strings) escapeShellArg;
            inherit (self.packages.${system}) hello;
            want = if traditional then
              "hello, world"
            else if greeting != "" then
              "${greeting}"
            else
              "Hello, world!";
            shellArgs = if traditional then
              "--traditional"
            else if greeting != "" then
              "--greeting=${escapeShellArg greeting}"
            else
              "";
            command = "${hello}/bin/hello ${shellArgs}";
          in (pkgs.runCommandNoCC "${checkName}" {
            meta.checkDescription = "${checkName}";
          } ''
            set -o verbose
            want='${want}'
            got="$(${command})"
            [ "$want" == "$got" ]
            touch $out
          '');
      in {
        hello = mkHelloCheck { checkName = "hello"; };

        helloTraditional = mkHelloCheck {
          checkName = "helloTraditional";
          traditional = true;
        };

        helloBryan = mkHelloCheck {
          checkName = "helloBryan";
          greeting = "Hello, Bryan!";
        };
      };

      pipelines.buildkite.steps = flake-buildkite-pipeline.lib.flakeSteps {
        commonExtraStepConfig = { agents = [ "nix" ]; };
      } self;
    };
}
