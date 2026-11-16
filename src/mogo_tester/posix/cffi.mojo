"""Glue for passing Mojo values across the C boundary.

Pointers cross the FFI boundary as `VoidPtr` values built from integer
addresses. Such pointers carry no origin, so they do not keep their owner
alive: Mojo may destroy a value right after its last use, which can be the
`addr`/`cstr` call itself. Callers must use the owning value again after the
C call returns (for example `_ = value^`) whenever the pointer is not
derived from a value that is still used later.
"""

comptime VoidPtr = MutOpaquePointer[MutAnyOrigin]
"""An untyped C pointer (`void *`)."""

comptime BytePtr = ImmPointer[UInt8, ImmutAnyOrigin]


@inline(.always)
def vp(address: Int) -> VoidPtr:
    """Returns an opaque pointer for an integer address."""
    return VoidPtr(unsafe_from_address=address)


@inline(.always)
def addr[T: Copyable](mut buf: List[T]) -> VoidPtr:
    """Returns a pointer to the first element of buf."""
    return vp(Int(buf.unsafe_ptr()))


@inline(.always)
def cstr(mut s: String) -> VoidPtr:
    """Returns a pointer to s as a NUL-terminated C string."""
    return vp(Int(s.as_c_string_span().ptr()))


def c_string_at(address: Int) -> String:
    """Copies the NUL-terminated C string at address into a String."""
    return String(unsafe_from_utf8_ptr=BytePtr(unsafe_from_address=address))


def load[T: TrivialRegisterPassable](address: Int) -> T:
    """Reads a T from address."""
    return Pointer[T, ImmutAnyOrigin](unsafe_from_address=address)[]


def store[T: TrivialRegisterPassable](address: Int, value: T):
    """Writes value to address."""
    Pointer[T, MutAnyOrigin](unsafe_from_address=address)[] = value


struct CStringArray(Movable):
    """A NULL-terminated `char *[]` that owns the strings it points to."""

    var strings: List[String]
    var pointers: List[Int]

    def __init__(out self, values: List[String]):
        self.strings = values.copy()
        self.pointers = List[Int](capacity=len(values) + 1)
        for i in range(len(self.strings)):
            self.pointers.append(Int(self.strings[i].as_c_string_span().ptr()))
        self.pointers.append(0)

    def ptr(mut self) -> VoidPtr:
        """Returns a pointer to the pointer array."""
        return addr(self.pointers)
