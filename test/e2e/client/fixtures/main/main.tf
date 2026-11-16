# Providers from both registries, so both file routes (github, hashicorp) are used;
# modules from the fake GitHub through the git cache, a tag, a branch and the default branch.
terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "3.9.1" }
    time   = { source = "hashicorp/time", version = "0.14.2" }
    null   = { source = "registry.terraform.io/hashicorp/null", version = "3.2.4" }
  }
}

module "tagged" {
  source = "git::https://github.com/acme/mod.git?ref=v1.0.0"
}

module "branch" {
  source = "git::https://github.com/acme/mod.git?ref=main"
}

module "default" {
  source = "git::https://github.com/acme/mod.git"
}
