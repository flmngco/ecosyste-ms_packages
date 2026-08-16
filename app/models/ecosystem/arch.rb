# frozen_string_literal: true

module Ecosystem
  class Arch < Base
    # The repositories a stock Arch install has enabled. The testing, staging and
    # unstable repositories hold newer builds of names that are already in these,
    # so including them would give two records for the same package name.
    #
    # The search interface can filter on these itself, but only through a repeated
    # repo parameter, which the shared Faraday connection collapses down to the
    # last value. Filtering the responses here avoids depending on that.
    REPOSITORIES = %w[core extra multilib].freeze

    MIRROR_URL = "https://geo.mirror.pkgbuild.com"

    # Packages built for "any" are published under the x86_64 tree on mirrors.
    MIRROR_ARCHITECTURE = "x86_64"

    def self.purl_type
      "alpm"
    end

    def sync_in_batches?
      true
    end

    def has_dependent_repos?
      false
    end

    def purl_params(package, version = nil)
      {
        type: purl_type,
        namespace: "arch",
        name: package.name.encode("iso-8859-1"),
        version: version.try(:number).try(:encode, "iso-8859-1"),
        qualifiers: { "arch" => package.metadata&.dig("architecture") }.compact_blank,
      }.compact_blank
    end

    def registry_url(package, _version = nil)
      repository = package.metadata&.dig("repository")
      architecture = package.metadata&.dig("architecture")

      if repository.blank? || architecture.blank?
        return "#{@registry_url}/packages/?q=#{ERB::Util.url_encode(package.name)}"
      end

      "#{@registry_url}/packages/#{repository}/#{architecture}/#{package.name}/"
    end

    def download_url(package, version)
      return nil if version.blank?

      repository = package.metadata&.dig("repository")
      filename = version.metadata&.dig("filename")
      return nil if repository.blank? || filename.blank?

      "#{MIRROR_URL}/#{repository}/os/#{mirror_architecture(package)}/#{filename}"
    end

    def install_command(package, _version = nil)
      "pacman -S #{package.name}"
    end

    def check_status(package)
      return "removed" if fetch_package(package.name).blank?
    end

    def all_package_names
      packages_by_name.keys.sort
    end

    def recently_updated_package_names
      packages_by_name
        .values
        .sort_by { |package| package["last_update"].to_s }
        .last(100)
        .reverse
        .map { |package| package["pkgname"] }
    end

    def packages_by_name
      @packages_by_name ||= fetch_all_packages.index_by { |package| package["pkgname"] }
    end

    # The web interface pages 250 records at a time and reports how many pages
    # there are, so the first response tells us when to stop.
    def fetch_all_packages
      packages = []
      page = 1
      pages = 1

      while page <= pages
        response = get_json("#{search_url}?page=#{page}")
        break unless response.is_a?(Hash)

        results = response["results"]
        break if results.blank?

        packages.concat(published(results))
        pages = response["num_pages"].to_i
        page += 1
      end

      packages
    rescue StandardError => e
      Rails.logger.error("Arch #{registry.name}: failed to load package index: #{e.message}")
      packages
    end

    def fetch_package_metadata_uncached(name)
      packages_by_name[name]
    end

    # Checking one package does not need the whole index paged in.
    def fetch_package(name)
      response = get_json("#{search_url}?name=#{ERB::Util.url_encode(name)}")
      return nil unless response.is_a?(Hash)

      published(response["results"].to_a).first
    end

    def map_package_metadata(pkg_metadata)
      return false if pkg_metadata.blank? || pkg_metadata["pkgname"].blank?

      {
        name: pkg_metadata["pkgname"],
        description: pkg_metadata["pkgdesc"],
        homepage: pkg_metadata["url"],
        licenses: Array(pkg_metadata["licenses"]).join(", "),
        repository_url: find_repository_url([pkg_metadata["url"]]),
        keywords_array: Array(pkg_metadata["groups"]),
        namespace: pkg_metadata["repo"],
        metadata: {
          repository: pkg_metadata["repo"],
          architecture: pkg_metadata["arch"],
          pkgbase: pkg_metadata["pkgbase"],
          packager: pkg_metadata["packager"],
          flagged_out_of_date_at: pkg_metadata["flag_date"],
        }.compact,
      }
    end

    def versions_metadata(pkg_metadata, existing_version_numbers = [])
      record = fetch_package_metadata(pkg_metadata[:name] || pkg_metadata["pkgname"])
      return [] if record.blank?

      number = version_number(record)
      return [] if number.blank? || existing_version_numbers.include?(number)

      [
        {
          number: number,
          published_at: record["build_date"],
          metadata: {
            filename: record["filename"],
            architecture: record["arch"],
            size: record["compressed_size"],
            installed_size: record["installed_size"],
          }.compact,
        },
      ]
    end

    # pacman version strings are epoch:pkgver-pkgrel, with the epoch left off
    # when it is zero. It has to be kept, or 2:9.0.1-1 reads as older than 9.0.1-1.
    def version_number(record)
      return nil if record["pkgver"].blank?

      number = "#{record['pkgver']}-#{record['pkgrel']}"
      epoch = record["epoch"].to_i

      epoch.zero? ? number : "#{epoch}:#{number}"
    end

    def mirror_architecture(package)
      architecture = package.metadata&.dig("architecture")
      return MIRROR_ARCHITECTURE if architecture.blank? || architecture == "any"

      architecture
    end

    def search_url
      "#{@registry_url}/packages/search/json/"
    end

    private

    def published(results)
      results.select { |package| REPOSITORIES.include?(package["repo"]) }
    end
  end
end
