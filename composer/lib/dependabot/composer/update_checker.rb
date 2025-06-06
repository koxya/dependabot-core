# typed: strict
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require "dependabot/errors"
require "dependabot/requirements_update_strategy"
require "dependabot/shared_helpers"
require "dependabot/update_checkers"
require "dependabot/update_checkers/base"

module Dependabot
  module Composer
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      extend T::Sig

      require_relative "update_checker/requirements_updater"
      require_relative "update_checker/version_resolver"
      require_relative "update_checker/latest_version_finder"

      sig { override.returns(T.nilable(T.any(String, Gem::Version))) }
      def latest_version
        return nil if path_dependency?
        return latest_version_for_git_dependency if git_dependency?

        # Fall back to latest_resolvable_version if no listings found
        latest_version_from_registry || latest_resolvable_version
      end

      sig { override.returns(T.nilable(Dependabot::Version)) }
      def latest_resolvable_version
        return nil if path_dependency? || git_dependency?

        @latest_resolvable_version ||= T.let(
          VersionResolver.new(
            credentials: credentials,
            dependency: dependency,
            dependency_files: dependency_files,
            latest_allowable_version: latest_version_from_registry,
            requirements_to_unlock: :own
          ).latest_resolvable_version,
          T.nilable(Dependabot::Version)
        )
      end

      sig { override.returns(T.nilable(Dependabot::Version)) }
      def lowest_security_fix_version
        latest_version_finder.lowest_security_fix_version
      end

      sig { override.returns(T.nilable(Dependabot::Version)) }
      def lowest_resolvable_security_fix_version
        raise "Dependency not vulnerable!" unless vulnerable?

        @lowest_resolvable_security_fix_version ||= T.let(
          fetch_lowest_resolvable_security_fix_version,
          T.nilable(Dependabot::Version)
        )
      end

      sig { override.returns(T.nilable(Dependabot::Version)) }
      def latest_resolvable_version_with_no_unlock
        return nil if path_dependency? || git_dependency?

        @latest_resolvable_version_with_no_unlock ||= T.let(
          VersionResolver.new(
            credentials: credentials,
            dependency: dependency,
            dependency_files: dependency_files,
            latest_allowable_version: latest_version_from_registry,
            requirements_to_unlock: :none
          ).latest_resolvable_version,
          T.nilable(Dependabot::Version)
        )
      end

      sig { override.returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def updated_requirements
        RequirementsUpdater.new(
          requirements: dependency.requirements,
          latest_resolvable_version: preferred_resolvable_version&.to_s,
          update_strategy: T.must(requirements_update_strategy)
        ).updated_requirements
      end

      sig { returns(T::Boolean) }
      def requirements_unlocked_or_can_be?
        !requirements_update_strategy&.lockfile_only?
      end

      sig { returns(T.nilable(Dependabot::RequirementsUpdateStrategy)) }
      def requirements_update_strategy
        # If passed in as an option (in the base class) honour that option
        return @requirements_update_strategy if @requirements_update_strategy

        # Otherwise, widen ranges for libraries and bump versions for apps
        library? ? RequirementsUpdateStrategy::WidenRanges : RequirementsUpdateStrategy::BumpVersionsIfNecessary
      end

      private

      sig { override.returns(T::Boolean) }
      def latest_version_resolvable_with_full_unlock?
        # Full unlock checks aren't implemented for Composer (yet)
        false
      end

      sig { override.returns(T::Array[Dependabot::Dependency]) }
      def updated_dependencies_after_full_unlock
        raise NotImplementedError
      end

      sig { returns(T.nilable(Dependabot::Version)) }
      def latest_version_from_registry
        latest_version_finder.latest_version
      end

      sig { returns(Dependabot::Composer::UpdateChecker::LatestVersionFinder) }
      def latest_version_finder
        @latest_version_finder ||= T.let(
          LatestVersionFinder.new(
            dependency: dependency,
            dependency_files: dependency_files,
            credentials: credentials,
            ignored_versions: ignored_versions,
            raise_on_ignored: raise_on_ignored,
            security_advisories: security_advisories,
            cooldown_options: update_cooldown
          ),
          T.nilable(Dependabot::Composer::UpdateChecker::LatestVersionFinder)
        )
      end

      sig { returns(T.nilable(Dependabot::Version)) }
      def fetch_lowest_resolvable_security_fix_version
        return nil if path_dependency? || git_dependency?

        fix_version = lowest_security_fix_version
        return latest_resolvable_version if fix_version.nil?

        resolved_fix_version = VersionResolver.new(
          credentials: credentials,
          dependency: dependency,
          dependency_files: dependency_files,
          latest_allowable_version: fix_version,
          requirements_to_unlock: :own
        ).latest_resolvable_version

        return fix_version if fix_version == resolved_fix_version

        latest_resolvable_version
      end

      sig { returns(T::Boolean) }
      def path_dependency?
        dependency.requirements.any? { |r| r.dig(:source, :type) == "path" }
      end

      # To be a true git dependency, it must have a branch.
      sig { returns(T::Boolean) }
      def git_dependency?
        dependency.requirements.any? { |r| r.dig(:source, :branch) }
      end

      sig { returns(Dependabot::DependencyFile) }
      def composer_file
        composer_file =
          dependency_files.find { |f| f.name == PackageManager::MANIFEST_FILENAME }
        raise "No #{PackageManager::MANIFEST_FILENAME}!" unless composer_file

        composer_file
      end

      sig { returns(T::Boolean) }
      def library?
        JSON.parse(T.must(composer_file.content))["type"] == "library"
      end

      sig { returns(T.nilable(String)) }
      def latest_version_for_git_dependency
        # If the dependency isn't pinned then we just want to check that it
        # points to the latest commit on the relevant branch.
        return git_commit_checker.head_commit_for_current_branch unless git_commit_checker.pinned?

        # If the dependency is pinned to a tag that looks like a version then
        # we want to update that tag. The latest version will then be the SHA
        # of the latest tag that looks like a version.
        if git_commit_checker.pinned_ref_looks_like_version? &&
           git_commit_checker.local_tag_for_latest_version
          latest_tag = git_commit_checker.local_tag_for_latest_version
          return latest_tag&.fetch(:commit_sha)
        end

        # If the dependency is pinned to a tag that doesn't look like a
        # version then there's nothing we can do.
        dependency.version
      end

      sig { returns(Dependabot::GitCommitChecker) }
      def git_commit_checker
        @git_commit_checker ||= T.let(
          Dependabot::GitCommitChecker.new(
            dependency: dependency,
            credentials: credentials,
            ignored_versions: ignored_versions,
            raise_on_ignored: raise_on_ignored
          ),
          T.nilable(Dependabot::GitCommitChecker)
        )
      end
    end
  end
end

Dependabot::UpdateCheckers
  .register("composer", Dependabot::Composer::UpdateChecker)
