all: pkgIndex.tcl new-tiles.png new-tiles-large.png

pkgIndex.tcl: mahjong-svg.tcl mahjong-png.tcl
	echo pkg_mkIndex . | tclsh

new-tiles.png: new-tiles.svg
	inkscape -e new-tiles.png new-tiles.svg

new-tiles-large.png: new-tiles.svg
	inkscape -e new-tiles.png -w 7524 new-tiles.svg

