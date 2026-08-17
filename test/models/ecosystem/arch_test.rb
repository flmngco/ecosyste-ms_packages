# frozen_string_literal: true

require "test_helper"

class ArchTest < ActiveSupport::TestCase
  setup do
    @registry = Registry.new(default: true, name: "archlinux.org", url: "https://archlinux.org", ecosystem: "arch")
    @ecosystem = Ecosystem::Arch.new(@registry)
    @package = Package.new(ecosystem: "arch", name: "wget", metadata: { "repository" => "extra", "architecture" => "x86_64" })
    @version = @package.versions.build(number: "1.25.0-6", metadata: { "filename" => "wget-1.25.0-6-x86_64.pkg.tar.zst" })
    @maintainer = @registry.maintainers.build(login: "anthraxx")
  end

  def stub_index
    stub_request(:get, "#{search_url}?page=1")
      .to_return({ status: 200, body: file_fixture("arch/packages-1") })
    stub_request(:get, "#{search_url}?page=2")
      .to_return({ status: 200, body: file_fixture("arch/packages-2") })
    stub_request(:get, "#{search_url}?page=3")
      .to_return({ status: 200, body: file_fixture("arch/packages-3") })
  end

  def search_url
    "https://archlinux.org/packages/search/json/"
  end

  test "registry_url" do
    registry_url = @ecosystem.registry_url(@package)
    assert_equal "https://archlinux.org/packages/extra/x86_64/wget/", registry_url
  end

  test "registry_url falls back to a search without repository metadata" do
    package = Package.new(ecosystem: "arch", name: "wget")

    assert_equal "https://archlinux.org/packages/?q=wget", @ecosystem.registry_url(package)
  end

  test "download_url" do
    download_url = @ecosystem.download_url(@package, @version)
    assert_equal "https://geo.mirror.pkgbuild.com/extra/os/x86_64/wget-1.25.0-6-x86_64.pkg.tar.zst", download_url
  end

  test "download_url for an any package uses the x86_64 tree" do
    package = Package.new(ecosystem: "arch", name: "adwaita-fonts", metadata: { "repository" => "extra", "architecture" => "any" })
    version = package.versions.build(number: "50.0-1", metadata: { "filename" => "adwaita-fonts-50.0-1-any.pkg.tar.zst" })

    assert_equal "https://geo.mirror.pkgbuild.com/extra/os/x86_64/adwaita-fonts-50.0-1-any.pkg.tar.zst",
                 @ecosystem.download_url(package, version)
  end

  test "download_url without a version returns nil" do
    assert_nil @ecosystem.download_url(@package, nil)
  end

  test "install_command" do
    assert_equal "pacman -S wget", @ecosystem.install_command(@package)
  end

  test "purl" do
    purl = @ecosystem.purl(@package)
    assert_equal "pkg:alpm/arch/wget?arch=x86_64", purl
    assert Purl.parse(purl)
  end

  test "purl with version" do
    purl = @ecosystem.purl(@package, @version)
    assert_equal "pkg:alpm/arch/wget@1.25.0-6?arch=x86_64", purl
    assert Purl.parse(purl)
  end

  test "the alpm purl type maps back to the ecosystem" do
    assert_equal "arch", Ecosystem::Base.purl_type_to_ecosystem("alpm")
  end

  test "all_package_names" do
    stub_index

    assert_equal %w[adwaita-fonts akonadi ffmpeg gcc lib32-curl lib32-openssl libisl
                    nextcloud-app-calendar openssl wget zlib zlib-ng-compat],
                 @ecosystem.all_package_names
  end

  test "recently_updated_package_names returns the most recently updated first" do
    stub_index

    assert_equal %w[ffmpeg nextcloud-app-calendar gcc wget libisl akonadi lib32-curl
                    openssl lib32-openssl zlib adwaita-fonts zlib-ng-compat],
                 @ecosystem.recently_updated_package_names
  end

  test "fetch_all_packages raises rather than returning a truncated index" do
    stub_request(:get, "#{search_url}?page=1")
      .to_return({ status: 200, body: file_fixture("arch/packages-1") })
    stub_request(:get, "#{search_url}?page=2")
      .to_return({ status: 200, body: file_fixture("arch/missing") })

    error = assert_raises(RuntimeError) { @ecosystem.all_package_names }
    assert_match "page 2 of 3", error.message
  end

  test "fetch_all_packages gives up on a page that keeps failing" do
    stub_request(:get, "#{search_url}?page=1").to_timeout

    error = assert_raises(RuntimeError) { @ecosystem.all_package_names }
    assert_match "could not read page 1", error.message
  end

  test "fetch_all_packages retries a page that comes back as something other than JSON" do
    stub_request(:get, "#{search_url}?page=1")
      .to_return({ status: 200, body: "<html>bad gateway</html>" })
      .then.to_return({ status: 200, body: file_fixture("arch/packages-1") })
    stub_request(:get, "#{search_url}?page=2")
      .to_return({ status: 200, body: file_fixture("arch/packages-2") })
    stub_request(:get, "#{search_url}?page=3")
      .to_return({ status: 200, body: file_fixture("arch/packages-3") })

    assert_includes @ecosystem.all_package_names, "wget"
  end

  # akonadi is in extra and, at a newer version, in kde-unstable.
  test "package_metadata ignores builds from repositories that are not enabled" do
    stub_index
    package_metadata = @ecosystem.package_metadata("akonadi")

    assert_equal "extra", package_metadata[:metadata][:repository]
    assert_equal "26.04.3-1", @ecosystem.versions_metadata({ name: "akonadi" }).first[:number]
  end

  test "fetch_package ignores builds from repositories that are not enabled" do
    stub_request(:get, "#{search_url}?name=akonadi")
      .to_return({ status: 200, body: file_fixture("arch/akonadi") })

    assert_equal "extra", @ecosystem.fetch_package("akonadi")["repo"]
  end

  test "package_metadata" do
    stub_index
    package_metadata = @ecosystem.package_metadata("gcc")

    assert_equal "gcc", package_metadata[:name]
    assert_equal "The GNU Compiler Collection - C and C++ frontends", package_metadata[:description]
    assert_equal "https://gcc.gnu.org", package_metadata[:homepage]
    assert_equal "core", package_metadata[:namespace]
    assert_equal [], package_metadata[:keywords_array]
    assert_equal "core", package_metadata[:metadata][:repository]
    assert_equal "x86_64", package_metadata[:metadata][:architecture]
    assert_equal "gcc", package_metadata[:metadata][:pkgbase]
    assert_equal "freswa", package_metadata[:metadata][:packager]
  end

  test "map_package_metadata takes a repository url from a forge homepage" do
    package_metadata = @ecosystem.map_package_metadata(
      "pkgname" => "ripgrep",
      "repo" => "extra",
      "arch" => "x86_64",
      "url" => "https://github.com/BurntSushi/ripgrep",
      "licenses" => ["MIT"]
    )

    assert_equal "https://github.com/BurntSushi/ripgrep", package_metadata[:repository_url]
  end

  test "map_package_metadata leaves the repository url unset for other homepages" do
    stub_index
    package_metadata = @ecosystem.package_metadata("gcc")

    assert_equal "https://gcc.gnu.org", package_metadata[:homepage]
    assert_nil package_metadata[:repository_url]
  end

  test "package_metadata records when a package was flagged out of date" do
    stub_index
    package_metadata = @ecosystem.package_metadata("adwaita-fonts")

    assert_equal "2026-08-04T12:59:54.469Z", package_metadata[:metadata][:flagged_out_of_date_at]
  end

  # Arch publishes SPDX identifiers, so joining them with AND keeps the field a
  # valid SPDX expression. Joining with a comma does not, and the fallback
  # matching then reads "GPL-3.0-or-later WITH GCC-exception-3.1" as
  # BSD-3-Clause-Attribution.
  test "package_metadata joins licences into an SPDX expression" do
    stub_index
    package_metadata = @ecosystem.package_metadata("gcc")

    assert_equal "GFDL-1.3-or-later AND GPL-3.0-or-later WITH GCC-exception-3.1", package_metadata[:licenses]

    package = Package.new(licenses: package_metadata[:licenses])
    package.send(:normalize_licenses)
    assert_equal ["GFDL-1.3-or-later", "GPL-3.0-or-later"], package.normalized_licenses
  end

  test "versions_metadata" do
    stub_index
    versions_metadata = @ecosystem.versions_metadata({ name: "wget" })

    assert_equal [
      {
        number: "1.25.0-6",
        published_at: "2026-07-15T17:45:33Z",
        metadata: {
          filename: "wget-1.25.0-6-x86_64.pkg.tar.zst",
          architecture: "x86_64",
          size: 721_480,
          installed_size: 5_974_018,
        },
      },
    ], versions_metadata
  end

  test "versions_metadata keeps a non-zero epoch in the version number" do
    stub_index
    versions_metadata = @ecosystem.versions_metadata({ name: "ffmpeg" })

    assert_equal "2:9.0.1-1", versions_metadata.first[:number]
  end

  test "versions_metadata skips a version already recorded" do
    stub_index

    assert_equal [], @ecosystem.versions_metadata({ name: "wget" }, ["1.25.0-6"])
  end

  test "dependencies_metadata" do
    stub_index
    dependencies = @ecosystem.dependencies_metadata("gcc", "16.2.1+r23+gd564253eb6c8-1", nil)

    assert_equal [
      { package_name: "binutils", requirements: ">=2.28", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "glibc", requirements: ">=2.27", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "gmp", requirements: "*", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "libasan", requirements: "=16.2.1+r23+gd564253eb6c8-1", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "libisl", requirements: "*", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "zlib", requirements: "*", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "lib32-gcc-libs", requirements: "*", kind: "runtime", optional: true, ecosystem: "arch" },
      { package_name: "doxygen", requirements: "*", kind: "build", optional: false, ecosystem: "arch" },
      { package_name: "python", requirements: "*", kind: "build", optional: false, ecosystem: "arch" },
      { package_name: "dejagnu", requirements: "*", kind: "test", optional: false, ecosystem: "arch" },
      { package_name: "inetutils", requirements: "*", kind: "test", optional: false, ecosystem: "arch" },
    ], dependencies
  end

  # gcc depends on libisl.so=23-64 without naming libisl, which provides it.
  test "dependencies_metadata resolves a shared object to the package providing it" do
    stub_index
    names = @ecosystem.dependencies_metadata("gcc", "16.2.1+r23+gd564253eb6c8-1", nil)
      .map { |dependency| dependency[:package_name] }

    assert_includes names, "libisl"
    assert_not_includes names, "libisl.so"
  end

  # Nothing in the fixtures provides libidn2.so, so there is no package to point at.
  test "dependencies_metadata drops an unresolvable shared object" do
    stub_index
    dependencies = @ecosystem.dependencies_metadata("wget", "1.25.0-6", nil)

    assert_equal %w[glibc gnutls libidn2 ca-certificates autoconf-archive git],
                 dependencies.map { |dependency| dependency[:package_name] }
  end

  test "dependencies_metadata returns nothing for another version" do
    stub_index

    assert_equal [], @ecosystem.dependencies_metadata("wget", "1.24.0-1", nil)
  end

  # lib32-curl depends on libssl.so=3-32, which lib32-openssl provides and
  # openssl does not, even though both provide a libssl.so.
  test "dependencies_metadata resolves a shared object to the provider of the same word size" do
    stub_index
    names = @ecosystem.dependencies_metadata("lib32-curl", "8.21.0-1", nil)
      .map { |dependency| dependency[:package_name] }

    assert_includes names, "lib32-openssl"
    assert_not_includes names, "openssl"
  end

  # zlib and zlib-ng-compat both provide libz.so=1-64, so lib32-curl's
  # libz.so=1-32 has no single package behind it.
  test "dependencies_metadata drops a shared object with more than one provider" do
    stub_index
    names = @ecosystem.dependencies_metadata("lib32-curl", "8.21.0-1", nil)
      .map { |dependency| dependency[:package_name] }

    assert_not_includes names, "zlib"
    assert_not_includes names, "zlib-ng-compat"
    assert_equal %w[curl lib32-openssl], names
  end

  # nextcloud-app-calendar pins both ends of two ranges, and both bounds matter.
  test "dependencies_metadata keeps every constraint on the same package" do
    stub_index
    dependencies = @ecosystem.dependencies_metadata("nextcloud-app-calendar", "1:6.5.3-1", nil)

    assert_equal [
      { package_name: "nextcloud", requirements: ">=32", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "nextcloud", requirements: "<35", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "php-interpreter", requirements: ">=8.1", kind: "runtime", optional: false, ecosystem: "arch" },
      { package_name: "php-interpreter", requirements: "<8.6", kind: "runtime", optional: false, ecosystem: "arch" },
    ], dependencies
  end

  test "maintainer_url" do
    assert_equal "https://archlinux.org/packages/?maintainer=anthraxx", @ecosystem.maintainer_url(@maintainer)
  end

  test "maintainers_metadata" do
    stub_index
    maintainers_metadata = @ecosystem.maintainers_metadata("wget")

    assert_equal [
      { uuid: "anthraxx", login: "anthraxx", name: "anthraxx", url: "https://archlinux.org/packages/?maintainer=anthraxx" },
      { uuid: "Antiz", login: "Antiz", name: "Antiz", url: "https://archlinux.org/packages/?maintainer=Antiz" },
      { uuid: "blakkheim", login: "blakkheim", name: "blakkheim", url: "https://archlinux.org/packages/?maintainer=blakkheim" },
    ], maintainers_metadata
  end

  test "maintainers_metadata is empty for an orphaned package" do
    stub_index
    @ecosystem.packages_by_name["wget"]["maintainers"] = []

    assert_equal [], @ecosystem.maintainers_metadata("wget")
  end

  test "check_status marks a package that is no longer published as removed" do
    stub_request(:get, "#{search_url}?name=wget")
      .to_return({ status: 200, body: file_fixture("arch/missing") })

    assert_equal "removed", @ecosystem.check_status(@package)
  end

  test "check_status leaves a published package alone" do
    stub_request(:get, "#{search_url}?name=wget")
      .to_return({ status: 200, body: file_fixture("arch/wget") })

    assert_nil @ecosystem.check_status(@package)
  end
end
