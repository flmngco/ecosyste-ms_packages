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

    MULTILIB_PREFIX = "lib32-"

    PAGE_ATTEMPTS = 3

    DEPENDENCY_FIELDS = {
      "depends" => { kind: "runtime", optional: false },
      "optdepends" => { kind: "runtime", optional: true },
      "makedepends" => { kind: "build", optional: false },
      "checkdepends" => { kind: "test", optional: false },
    }.freeze

    def self.purl_type
      "alpm"
    end

    def sync_in_batches?
      true
    end

    def sync_maintainers_inline?
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

    def maintainer_url(maintainer)
      "#{@registry_url}/packages/?maintainer=#{maintainer.login}"
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

    def packages_by_provides
      @packages_by_provides ||= packages_by_name.each_value.with_object({}) do |package, index|
        Array(package["provides"]).each do |provided|
          name = provided.to_s.split("=").first.to_s.strip
          next if name.blank?

          (index[name] ||= []) << package["pkgname"]
        end
      end
    end

    # The web interface pages 250 records at a time and reports how many pages
    # there are, so the first response tells us when to stop.
    #
    # A page that cannot be read raises rather than returning what has been
    # collected so far. A truncated index is indistinguishable from a shrinking
    # registry, and the dependencies recorded from one would never be corrected,
    # because Registry#sync_package only writes dependencies alongside a version
    # it has not seen before.
    def fetch_all_packages
      packages = []
      page = 1
      pages = 1

      while page <= pages
        response = fetch_page(page)
        results = response["results"]
        raise "Arch #{registry.name} returned no packages for page #{page} of #{pages}" if results.blank?

        packages.concat(published(results))
        pages = response["num_pages"].to_i
        page += 1
      end

      packages
    end

    # A full crawl is 65 requests and now and then one comes back as something
    # other than JSON, so a page is retried a couple of times before the sync
    # gives up on the whole index.
    def fetch_page(page)
      attempts = 0

      begin
        attempts += 1
        response = get_json("#{search_url}?page=#{page}")
        return response if response.is_a?(Hash)

        raise "the response was not a JSON object"
      rescue StandardError => e
        raise "Arch #{registry.name} could not read page #{page}: #{e.message}" if attempts >= PAGE_ATTEMPTS

        Rails.logger.warn("Arch #{registry.name}: retrying page #{page} after #{e.message}")
        retry
      end
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
        licenses: Array(pkg_metadata["licenses"]).join(" AND "),
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

    def dependencies_metadata(name, version, _pkg_metadata)
      record = fetch_package_metadata(name)
      return [] if record.blank? || version_number(record) != version.to_s

      DEPENDENCY_FIELDS.flat_map do |field, attributes|
        dependencies_from_field(record[field], attributes, name)
      end.uniq { |dependency| [dependency[:package_name], dependency[:kind], dependency[:requirements]] }
    end

    # The search interface gives maintainers as Arch account names, without the
    # email addresses that the PKGBUILD carries.
    def maintainers_metadata(name)
      record = fetch_package_metadata(name)
      return [] if record.blank?

      Array(record["maintainers"]).filter_map do |login|
        login = login.to_s.strip
        next if login.blank?

        {
          uuid: login,
          login: login,
          name: login,
          url: "#{@registry_url}/packages/?maintainer=#{login}",
        }
      end
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

    def dependencies_from_field(atoms, attributes, consumer)
      Array(atoms).filter_map do |atom|
        package_name, requirements = parse_dependency(atom)
        next if package_name.blank?

        unless packages_by_name.key?(package_name)
          provider = package_providing(package_name, consumer)

          if provider.present?
            package_name = provider
            # The constraint applied to the name we resolved from rather than to
            # the package that provides it.
            requirements = "*"
          elsif package_name.end_with?(".so")
            # A shared object that no single package in the enabled repositories
            # accounts for. There is no package of that name to point at, so
            # there is nothing to record.
            next
          end
        end

        {
          package_name: package_name,
          requirements: requirements,
          kind: attributes[:kind],
          optional: attributes[:optional],
          ecosystem: self.class.lowercase_name,
        }
      end
    end

    # Atoms are a package name with an optional version constraint, for example
    # "glibc" or "zlib>=1.2". Constraints can carry an epoch, as in
    # "alsa-plugins=1:1.2.12", so the description that optdepends entries append
    # is split off on a colon followed by a space rather than on any colon.
    def parse_dependency(atom)
      atom = atom.to_s.split(": ").first.to_s.strip
      return nil if atom.blank?

      match = atom.match(/\A(?<name>[^<>=]+)(?<requirements>[<>=]+\S*)?\z/)
      return nil if match.blank?

      [match[:name].strip, match[:requirements].presence || "*"]
    end

    # Dependencies can name a shared object ("libisl.so=23-64") or a virtual
    # package ("sh") instead of a real one, and the package holding it is not
    # always listed alongside, so those go through the provides index.
    #
    # A 32 bit package means the 32 bit provider. lib32-curl depends on
    # libssl.so=3-32, which lib32-openssl provides and openssl does not, so the
    # candidates are narrowed to providers of the same word size first.
    #
    # If more than one candidate is left the name is returned unresolved. Several
    # packages provide java-runtime at different versions, and libz.so comes from
    # both zlib and zlib-ng-compat, and nothing in the index says which one a
    # given dependency meant. Picking one anyway would record a dependency the
    # package does not have.
    def package_providing(name, consumer)
      providers = packages_by_provides[name]
      return nil if providers.blank?

      multilib = consumer.to_s.start_with?(MULTILIB_PREFIX)
      candidates = providers.select { |provider| provider.start_with?(MULTILIB_PREFIX) == multilib }
      candidates = providers if candidates.empty?

      candidates.one? ? candidates.first : nil
    end
  end
end
