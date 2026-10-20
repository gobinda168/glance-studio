import Foundation
import Testing
@testable import GlanceCore

private func context(names: Set<String> = ["git", "ls", "cat", "python3", "pip3", "docker", "kubectl", "make", "npm",
                                           "pnpm", "yarn", "gh", "cargo", "brew", "mkdir", "cd", "chmod", "sudo", "ssh"],
                     files: Set<String> = ["README.md", "src/", "src/app/", "Makefile", "package.json"],
                     scripts: [String] = ["build", "dev", "test"], branches: [String] = ["main", "feature/login"])
  -> CorrectionContext {
  CorrectionContext(
    names: names,
    exists: { files.contains($0) || files.contains($0 + "/") },
    isDirectory: { files.contains($0.hasSuffix("/") ? $0 : $0 + "/") },
    list: { folder in
      let prefix = folder == "." || folder.isEmpty ? "" : (folder.hasSuffix("/") ? folder : folder + "/")
      let inside = files.filter { $0.hasPrefix(prefix) && $0 != prefix }.map { String($0.dropFirst(prefix.count)) }
      return inside.filter { !$0.dropLast($0.hasSuffix("/") ? 1 : 0).contains("/") }
    },
    scripts: scripts, branches: branches)
}

private func fix(_ command: String, _ output: String, exit: Int = 1, _ c: CorrectionContext = context()) -> String? {
  Corrections.fix(Failure(command: command, exitCode: exit, output: output, folder: "/proj"), c)
}

@Test func aMistypedCommandBecomesTheClosestOne() {
  #expect(fix("gti status", "zsh: command not found: gti", exit: 127) == "git status")
  #expect(fix("sl -la", "zsh: command not found: sl", exit: 127) == "ls -la")
  #expect(fix("dokcer ps", "zsh: command not found: dokcer", exit: 127) == "docker ps")
  #expect(fix("qwertyuiop", "zsh: command not found: qwertyuiop", exit: 127) == nil)
  #expect(fix("cd..", "zsh: command not found: cd..", exit: 127) == "cd ..")
  #expect(fix("python run.py", "zsh: command not found: python", exit: 127) == "python3 run.py")
  #expect(fix("pip install x", "zsh: command not found: pip", exit: 127) == "pip3 install x")
}

@Test func toolsThatSayDidYouMean() {
  #expect(fix("git psuh", "git: 'psuh' is not a git command. See 'git --help'.\n\nThe most similar command is\n\tpush\n")
    == "git push")
  #expect(fix("gh prr list", "unknown command \"prr\" for \"gh\"\n\nDid you mean this?\n\tpr\n\nUsage:  gh <command>")
    == "gh pr list")
  #expect(fix("npm isntall", "Unknown command: \"isntall\"\n\nDid you mean this?\n    npm install # Install a package\n")
    == "npm install")
  #expect(fix("cargo buidl", "error: no such command: `buidl`\n\n\tDid you mean `build`?\n\n\tView all installed commands")
    == "cargo build")
  #expect(fix("kubectl gett pods", "error: unknown command \"gett\" for \"kubectl\"\n\nDid you mean this?\n\tget\n")
    == "kubectl get pods")
  #expect(fix("uv pip install --verbos x", "error: unexpected argument '--verbos' found\n\n  tip: a similar argument exists: '--verbose'")
    == "uv pip install --verbose x")
}

@Test func gitPushWithNoUpstream() {
  let output = """
    fatal: The current branch feature/login has no upstream branch.
    To push the current branch and set the remote as upstream, use

        git push --set-upstream origin feature/login

    To have this happen automatically for branches without a tracking
    """
  #expect(fix("git push", output) == "git push --set-upstream origin feature/login")
}

@Test func gitBranches() {
  #expect(fix("git checkout mian", "error: pathspec 'mian' did not match any file(s) known to git") == "git checkout main")
  #expect(fix("git switch mian", "fatal: invalid reference: mian") == "git switch main")
  #expect(fix("git checkout newthing", "error: pathspec 'newthing' did not match any file(s) known to git")
    == "git checkout -b newthing")
  #expect(fix("git checkout -b main", "fatal: a branch named 'main' already exists") == "git checkout main")
  #expect(fix("git push", " ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to 'x'\nhint: Updates were rejected because the remote contains work")
    == "git pull && git push")
}

@Test func permissions() {
  #expect(fix("./deploy.sh prod", "zsh: permission denied: ./deploy.sh", exit: 126) == "chmod +x ./deploy.sh && ./deploy.sh prod")
  #expect(fix("mkdir /usr/local/thing", "mkdir: /usr/local/thing: Permission denied") == "sudo mkdir /usr/local/thing")
  // Never sudo before rm, never for ssh keys, never twice.
  #expect(fix("rm /etc/x", "rm: /etc/x: Permission denied") == nil)
  #expect(fix("git push", "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote") == nil)
  #expect(fix("sudo mkdir /x", "mkdir: /x: Permission denied") == nil)
}

@Test func foldersAndFiles() {
  #expect(fix("cd scr", "cd: no such file or directory: scr") == "cd src")
  #expect(fix("cd brandnew", "cd: no such file or directory: brandnew") == "mkdir -p brandnew && cd brandnew")
  #expect(fix("mkdir a/b/c", "mkdir: a/b: No such file or directory") == "mkdir -p a/b/c")
  #expect(fix("cat src", "cat: src: Is a directory") == "ls src")
  #expect(fix("cat READNE.md", "cat: READNE.md: No such file or directory") == "cat README.md")
  #expect(fix("git add READNE.md", "fatal: pathspec 'READNE.md' did not match any files") == "git add README.md")
}

@Test func missingPackageScripts() {
  #expect(fix("npm run biuld", "npm error Missing script: \"biuld\"\nnpm error\nnpm error To see a list of scripts, run:")
    == "npm run build")
  #expect(fix("pnpm run tset", " ERR_PNPM_NO_SCRIPT  Missing script: tset\n\nCommand \"tset\" not found.") == "pnpm run test")
  #expect(fix("pnpm dve", "ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL  Command \"dve\" not found") == "pnpm dev")
  #expect(fix("yarn biuld", "error Command \"biuld\" not found.") == "yarn build")
}

/// The tool's own "Did you mean" wins over edit distance: "dev" is too far from "dev:web" to be guessed.
@Test func packageScriptsTheToolSuggests() {
  let koro = context(scripts: ["dev:web", "build:web", "dev:api", "test", "check"])
  #expect(fix("pnpm dev", " ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL  Command \"dev\" not found\n\nDid you mean \"pnpm dev:web\"?",
              koro) == "pnpm dev:web")
  #expect(fix("pnpm dev --port 3000", "ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL  Command \"dev\" not found\n\nDid you mean \"pnpm dev:web\"?",
              koro) == "pnpm dev:web --port 3000")
  #expect(fix("yarn dev", "error Command \"dev\" not found. Did you mean \"dev:web\"?", koro) == "yarn dev:web")
  #expect(fix("npm run tst", "npm error Missing script: \"tst\"\nnpm error\nnpm error Did you mean this?\nnpm error   npm test # Run tests\nnpm error",
              koro) == "npm run test")
}

@Test func noRuleMakesACommandMoreDestructive() {
  #expect(!Corrections.isSafe(original: "git push", fix: "git push --force"))
  #expect(!Corrections.isSafe(original: "git branch -d x", fix: "git branch -D x"))
  #expect(!Corrections.isSafe(original: "rm x", fix: "rm -r x"))
  #expect(!Corrections.isSafe(original: "rm x", fix: "sudo rm x"))
  #expect(!Corrections.isSafe(original: "git reset x", fix: "git reset --hard x"))
  #expect(Corrections.isSafe(original: "gti push", fix: "git push"))
  #expect(Corrections.isSafe(original: "mkdir /x", fix: "sudo mkdir /x"))
}

@Test func nothingForSuccessOrInterrupts() {
  #expect(fix("gti", "zsh: command not found: gti", exit: 0) == nil)
  #expect(fix("gti", "zsh: command not found: gti", exit: 130) == nil)
  #expect(fix("yes | head", "", exit: 141) == nil)
  #expect(fix("vim", "", exit: 148) == nil)
  #expect(fix("make", "make: *** [all] Error 2", exit: 2) == nil)
}

@Test func editDistanceCountsSwapsAsOne() {
  #expect(Corrections.distance("gti", "git") == 1)
  #expect(Corrections.distance("git", "git") == 0)
  #expect(Corrections.distance("dokcer", "docker") == 1)
  #expect(Corrections.distance("kitten", "sitting") == 3)
}

@Test func aTypoOfACommandThatWorkedBeforeBecomesIt() {
  var c = context()
  c.history = [PastCommand(command: "pnpm run dev:web", count: 9, here: true),
               PastCommand(command: "git status", count: 40, here: false)]
  c.names.insert("pnpm")
  #expect(fix("pnpm run dev:wbe", "zsh: command not found: dev:wbe", exit: 127, c) == "pnpm run dev:web")
  // A command that ran and failed is not a typo, however near another one is.
  #expect(fix("git statu", "error: build failed", exit: 2, c) == nil)
}

@Test func historyNeedsItsPathsToExist() {
  var c = context()
  c.history = [PastCommand(command: "cd src/api", count: 3, here: true)]
  #expect(fix("cd src/apj", "cd: no such file or directory: src/apj", c) != "cd src/api")
}
