class Hoz < Formula
  desc "Git-compatible version control system written in Zig"
  homepage "https://github.com/Edward/hoz"
  url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-0.1.1-macos-x86_64.tar.gz"
  sha256 "PLACEHOLDER_MACOS_X86_64_SHA256"
  license "MIT"
  version "0.1.1"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-0.1.1-macos-aarch64.tar.gz"
      sha256 "PLACEHOLDER_MACOS_AARCH64_SHA256"
    end
  end

  on_linux do
    url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-0.1.1-linux-x86_64.tar.gz"
    sha256 "PLACEHOLDER_LINUX_X86_64_SHA256"
  end

  def install
    bin.install "hoz"
  end

  test do
    system "#{bin}/hoz", "--version"
  end
end