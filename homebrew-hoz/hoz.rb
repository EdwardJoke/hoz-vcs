class Hoz < Formula
  desc "Git-compatible version control system in Zig"
  homepage "https://github.com/Edward/hoz"
  license "MIT"
  version "0.1.1"

  on_macos do
    on_intel do
      url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-x86_64-macos.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_arm do
      url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-aarch64-macos.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_x86_64 do
      url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-x86_64-linux.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_arm64 do
      url "https://github.com/Edward/hoz/releases/download/v0.1.1/hoz-aarch64-linux.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    bin.install "hoz"
  end

  test do
    system "#{bin}/hoz", "version"
  end
end