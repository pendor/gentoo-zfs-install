#!/bin/bash
# Takes a dump of a GPT header and computes its checksums
#
# Create the dump with:
#   dd if=/dev/sdc of=gpt1.bin bs=512 skip=1 count=33
#
# Or for an secondary GPT do:
#   dd if=/dev/sdc of=gpt2.bin bs=512 count=33 skip=$((`sfdisk -s /dev/sdc 2>/dev/null` * 2 - 33))

if [ "$1" != "end" ] && [ "$1" != "start" ] ; then
	echo "Usage: $0 <end|start> <bin file>"
	exit 1
fi

rm -f tmp-head.bin tmp-tbl.bin tmp-head-crc.bin

if [ "$1" == "start" ] ; then
	dd if="$2" bs=512 count=1 of=tmp-head.bin >/dev/null 2>&1
	dd if="$2" bs=512 skip=1 count=32 of=tmp-tbl.bin >/dev/null 2>&1
else
	dd if="$2" bs=512 skip=32 count=1 of=tmp-head.bin >/dev/null 2>&1
	dd if="$2" bs=512 count=32 of=tmp-tbl.bin >/dev/null 2>&1
fi

echo -n "Magic: "
dd if=tmp-head.bin bs=1 count=8 2>/dev/null
echo ""

HDRSIZE=`perl -e 'open(HDR, "tmp-head.bin"); binmode(HDR); seek(HDR, 12, 0); read(HDR, $val, 4); print(unpack("V", $val)); close(HDR);'`

echo "Header size: $HDRSIZE"

echo -n "Header CRC: "
dd if=tmp-head.bin of=tmp-head-crc.bin bs=1 count=$HDRSIZE >/dev/null 2>&1
dd if=/dev/zero of=tmp-head-crc.bin bs=1 count=4 seek=16 conv=notrunc >/dev/null 2>&1
crc32 tmp-head-crc.bin

echo -n "Partition table CRC: "
crc32 tmp-tbl.bin

#rm -f tmp-head.bin tmp-tbl.bin tmp-head-crc.bin
