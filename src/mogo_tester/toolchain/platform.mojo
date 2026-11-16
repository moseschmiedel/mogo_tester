"""Build target platforms, named by their Mojo target triple."""

from std.sys import CompilationTarget


@fieldwise_init
struct Platform(Equatable, ImplicitlyCopyable, Writable):
    """An operating system and CPU architecture that Mojo targets.

    Platforms are written as the target triple Mojo uses to describe a build
    target, such as `aarch64-apple-macosx` or `x86_64-unknown-linux-gnu`.
    """

    var _value: Int

    comptime AARCH64_APPLE_MACOSX = Self(0)
    """macOS on Apple silicon."""
    comptime X86_64_APPLE_MACOSX = Self(1)
    """macOS on Intel."""
    comptime X86_64_UNKNOWN_LINUX_GNU = Self(2)
    """Linux on x86-64."""
    comptime AARCH64_UNKNOWN_LINUX_GNU = Self(3)
    """Linux on AArch64."""

    @staticmethod
    def current() -> Self:
        """Returns the platform this binary was compiled for."""
        comptime if CompilationTarget.is_macos():
            comptime if CompilationTarget.is_arm():
                return Self.AARCH64_APPLE_MACOSX
            else:
                return Self.X86_64_APPLE_MACOSX
        else:
            comptime if CompilationTarget.is_x86():
                return Self.X86_64_UNKNOWN_LINUX_GNU
            else:
                return Self.AARCH64_UNKNOWN_LINUX_GNU

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to(self, mut writer: Some[Writer]):
        match self:
            case .AARCH64_APPLE_MACOSX:
                writer.write("aarch64-apple-macosx")
            case .X86_64_APPLE_MACOSX:
                writer.write("x86_64-apple-macosx")
            case .X86_64_UNKNOWN_LINUX_GNU:
                writer.write("x86_64-unknown-linux-gnu")
            case .AARCH64_UNKNOWN_LINUX_GNU:
                writer.write("aarch64-unknown-linux-gnu")
