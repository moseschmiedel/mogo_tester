"""Process environment variables."""

from . import libc
from .cffi import c_string_at, load


struct Environment(Copyable, Movable, Sized):
    """An ordered set of environment variables.

    Keys are unique; `set` replaces an existing value in place and appends
    new keys, so the original order of the process environment is kept.
    """

    var _keys: List[String]
    var _values: List[String]

    def __init__(out self):
        """Creates an empty environment."""
        self._keys = List[String]()
        self._values = List[String]()

    @staticmethod
    def current(out result: Self):
        """Returns a snapshot of the calling process's environment."""
        result = Self()
        var entries = libc.environ()
        if entries == 0:
            return
        var i = 0
        while True:
            var entry = load[Int](entries + i * 8)
            if entry == 0:
                break
            result.set_entry(c_string_at(entry))
            i += 1

    def __len__(self) -> Int:
        return len(self._keys)

    def __contains__(self, key: String) -> Bool:
        return self._index(key) >= 0

    def get(self, key: String) -> Optional[String]:
        """Returns the value of key, or None if it is unset."""
        var index = self._index(key)
        if index < 0:
            return None
        return self._values[index]

    def set(mut self, key: String, value: String):
        """Sets key to value, replacing any existing value."""
        var index = self._index(key)
        if index < 0:
            self._keys.append(key)
            self._values.append(value)
        else:
            self._values[index] = value

    def set_entry(mut self, entry: String):
        """Sets a variable from `KEY=VALUE` text. An entry without `=`
        sets KEY to the empty string."""
        var index = entry.find("=")
        if index < 0:
            self.set(entry, "")
        else:
            self.set(
                String(entry[byte=0:index]),
                String(entry[byte = index + 1 : entry.byte_length()]),
            )

    def unset(mut self, key: String):
        """Removes key if it is set."""
        var index = self._index(key)
        if index >= 0:
            _ = self._keys.pop(index)
            _ = self._values.pop(index)

    def update(mut self, other: Self):
        """Sets every variable from other, overriding existing values."""
        for i in range(len(other._keys)):
            self.set(other._keys[i], other._values[i])

    def entries(self, out result: List[String]):
        """Returns the variables as `KEY=VALUE` text, in order."""
        result = List[String](capacity=len(self._keys))
        for i in range(len(self._keys)):
            result.append(self._keys[i] + "=" + self._values[i])

    def _index(self, key: String) -> Int:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return i
        return -1
