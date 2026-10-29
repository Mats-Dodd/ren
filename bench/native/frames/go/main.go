// Layer 3: a stream of length-prefixed records, little-endian, each a
// uint32 length, then a kind (byte), an id (binary.Uvarint), a time
// (int64), a value (int32) and a name (a byte length and its bytes),
// written into a []byte and read back through a cursor over it with
// encoding/binary, whose reads fail with a Short error when the input
// runs out, as Ren's do. Arithmetic is int64, as Ren's is.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strconv"
)

type Short struct{ At, Need int }

func (e *Short) Error() string { return fmt.Sprintf("Short(%d, %d)", e.At, e.Need) }

var errMalformed = errors.New("malformed")

type Cursor struct {
	b   []byte
	pos int
}

func (c *Cursor) left() int { return len(c.b) - c.pos }

func (c *Cursor) room(n int) error {
	if c.left() < n {
		return &Short{c.pos, n - c.left()}
	}
	return nil
}

func (c *Cursor) u8() (int64, error) {
	if err := c.room(1); err != nil {
		return 0, err
	}
	x := c.b[c.pos]
	c.pos++
	return int64(x), nil
}

func (c *Cursor) u32le() (int64, error) {
	if err := c.room(4); err != nil {
		return 0, err
	}
	x := binary.LittleEndian.Uint32(c.b[c.pos:])
	c.pos += 4
	return int64(x), nil
}

func (c *Cursor) i32le() (int64, error) {
	if err := c.room(4); err != nil {
		return 0, err
	}
	x := int32(binary.LittleEndian.Uint32(c.b[c.pos:]))
	c.pos += 4
	return int64(x), nil
}

func (c *Cursor) i64le() (int64, error) {
	if err := c.room(8); err != nil {
		return 0, err
	}
	x := int64(binary.LittleEndian.Uint64(c.b[c.pos:]))
	c.pos += 8
	return x, nil
}

func (c *Cursor) varuint() (int64, error) {
	z, n := binary.Uvarint(c.b[c.pos:])
	if n == 0 {
		return 0, &Short{c.pos, 1}
	}
	if n < 0 || z >= 1<<63 {
		return 0, errMalformed
	}
	c.pos += n
	return int64(z), nil
}

func (c *Cursor) skip(n int) error {
	if err := c.room(n); err != nil {
		return err
	}
	c.pos += n
	return nil
}

func idOf(i int64) int64 {
	bits := 7 * (1 + i%6)
	return i * 2654435761 % (int64(1) << bits)
}

func bodySize(i int64) int64 {
	return 1 + int64(len(binary.AppendUvarint(nil, uint64(idOf(i))))) + 8 + 4 + 1 + i%13
}

func input(n int64) []byte {
	var b []byte
	for i := int64(0); i < n; i++ {
		b = binary.LittleEndian.AppendUint32(b, uint32(bodySize(i)))
		b = append(b, byte(i%7))
		b = binary.AppendUvarint(b, uint64(idOf(i)))
		b = binary.LittleEndian.AppendUint64(b, uint64(i*1000003))
		b = binary.LittleEndian.AppendUint32(b, uint32(int32(i%1000-500)))
		name := i % 13
		b = append(b, byte(name))
		for j := int64(0); j < name; j++ {
			b = append(b, byte((i+j)%256))
		}
	}
	return b
}

func decode(b []byte) (int64, error) {
	c := Cursor{b, 0}
	var h int64
	for c.left() > 0 {
		l, err := c.u32le()
		if err != nil {
			return 0, err
		}
		start := c.pos
		kind, err := c.u8()
		if err != nil {
			return 0, err
		}
		id, err := c.varuint()
		if err != nil {
			return 0, err
		}
		t, err := c.i64le()
		if err != nil {
			return 0, err
		}
		value, err := c.i32le()
		if err != nil {
			return 0, err
		}
		name, err := c.u8()
		if err != nil {
			return 0, err
		}
		var s int64
		for k := int64(0); k < name; k++ {
			v, err := c.u8()
			if err != nil {
				return 0, err
			}
			s += v
		}
		if err := c.skip(start + int(l) - c.pos); err != nil {
			return 0, err
		}
		h = (h*31 + (kind + id%1000 + value + s)) ^ t
	}
	return h, nil
}

func main() {
	n, rounds := int64(1000000), int64(20)
	if len(os.Args) > 1 {
		n, _ = strconv.ParseInt(os.Args[1], 10, 64)
	}
	if len(os.Args) > 2 {
		rounds, _ = strconv.ParseInt(os.Args[2], 10, 64)
	}
	b := input(n)
	var x int64
	for r := int64(0); r < rounds; r++ {
		h, err := decode(b)
		if err != nil {
			x = -1
		} else {
			x += h
		}
	}
	fmt.Println(len(b))
	fmt.Println(x)
}
