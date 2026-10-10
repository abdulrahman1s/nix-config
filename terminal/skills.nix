{ lib, pkgs, username, ... }:

let
  repositories = {
    vercel-skills = pkgs.fetchFromGitHub {
      owner = "vercel-labs";
      repo = "skills";
      rev = "7407f3893ad4dceab546ac002c3ef806e4000c73";
      hash = "sha256-/B2el3+KYXohGCM4JaHl2EUx1c6mlYdUNrWiE0z/7lA=";
    };
    mattpocock = pkgs.fetchFromGitHub {
      owner = "mattpocock";
      repo = "skills";
      rev = "c55ee46073ed923f86ce59a5eb3b6d895095d1b7";
      hash = "sha256-L3CpIT2DeI+fUFl9fcygojtQo2DzEen69rMD1XqR1vM=";
    };
    resumeskills = pkgs.fetchFromGitHub {
      owner = "paramchoudhary";
      repo = "resumeskills";
      rev = "74ae19e7c62b0516d1c298328e5544976c12da5d";
      hash = "sha256-Mv1rSfP5TzeQiyt5+KLSJqPWBr7w6dEgqt4PuGE3hAc=";
    };
    cloudflare = pkgs.fetchFromGitHub {
      owner = "cloudflare";
      repo = "skills";
      rev = "6dc7604903127485e7e4cb26314651ebd4a4df19";
      hash = "sha256-5Qf3xeVzMrR0vE2oQZQypO63mE8Nz41GzxZT1fPDecA=";
    };
    anthropics = pkgs.fetchFromGitHub {
      owner = "anthropics";
      repo = "skills";
      rev = "34040c9c568585f6929bedeaad110ad08f079624";
      hash = "sha256-tI4bTTBfI1ylltklGyiyA7pLoKXEWtrT6lrmwrpLbCw=";
    };
    vercel-agent-skills = pkgs.fetchFromGitHub {
      owner = "vercel-labs";
      repo = "agent-skills";
      rev = "063bee94c3f4df8453406c830b0a7df0f2860278";
      hash = "sha256-tTSJf53OQltUfxTH4hdqcnw5ywCjCZP8/JqQ593cyB8=";
    };
    browser-use = pkgs.fetchFromGitHub {
      owner = "browser-use";
      repo = "browser-use";
      rev = "4cbe921673b48a488f5415d9159249afd12a625b";
      hash = "sha256-rkLZ0SsvHvjegCUaCZMxOFUONVd159oRuyQ7zJtFuIQ=";
    };
  };

  skills = {
    find-skills = "${repositories.vercel-skills}/skills/find-skills";
    codebase-design = "${repositories.mattpocock}/skills/engineering/codebase-design";
    resume-bullet-writer = "${repositories.resumeskills}/skills/resume-bullet-writer";
    wrangler = "${repositories.cloudflare}/skills/wrangler";
    frontend-design = "${repositories.anthropics}/skills/frontend-design";
    vercel-react-best-practices = "${repositories.vercel-agent-skills}/skills/react-best-practices";
    web-design-guidelines = "${repositories.vercel-agent-skills}/skills/web-design-guidelines";
    browser-use = "${repositories.browser-use}/skills/browser-use";
  };

  agentFiles = builtins.listToAttrs (lib.concatMap
    (name: map
      (agent: {
        name = "${agent}/skills/${name}";
        value = {
          source = skills.${name};
          # Replace the existing manual install, whose SKILL.md matches this revision.
          clobber = name == "find-skills" && agent == ".agents";
        };
      })
      [ ".agents" ".claude" ])
    (builtins.attrNames skills));
  rtkSkill = "/home/${username}/system-conf/.agents/skills/rtk/SKILL.md";
in
{
  hjem.users.${username}.files = agentFiles // {
    ".agents/skills/rtk/SKILL.md".source = rtkSkill;
    ".claude/skills/rtk/SKILL.md".source = rtkSkill;
  };
}
