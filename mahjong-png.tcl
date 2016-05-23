# -*- mode: Tcl; tab-width: 8; -*-
#
# Copyright (C) 2016 by Roger E Critchlow Jr, Cambridge, MA, USA.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
# 

package provide mahjong-png 1.0

package require Tk
package require snit

#
# translate a subset of svg into canvas graphics
# make the <defs></defs> in an svg file available
# for rendering as canvas items, and cache the
# translation
#
snit::type mahjong::png {
    option -file -default {} -readonly true
    option -data -default {} -readonly true
    option -tile-width -default 64 -readonly true
    option -tile-height -default 88 -readonly true
    option -tiles -readonly true
    
    component img
    component tmp

    variable data [dict create num 1 den 1]

    constructor {args} {
	$self configure {*}$args
	if {$options(-data) ne {}} {
	    set img [image create photo -data $options(-data)] 
	} elseif {$options(-file) ne {}} {
	    set img [image create photo -file $options(-file)]
	} else {
	    error "png needs -data or -file option specified"
	}
	set tmp [image create photo]
	dict set data noscale [catch {$tmp copy $img -scale 0.99}]
	$tmp copy $img
	set options(-tile-width) [expr {[image width $img]/44}]
	set options(-tile-height) [image height $img]
	#puts "png tile width $options(-tile-width) height $options(-tile-height)"

	foreach tile $options(-tiles) {
	    dict set data $tile [image create photo]
	    set ix [lsearch $options(-tiles) $tile]
	    set x0 [expr {$ix*$options(-tile-width)}]
	    set y0 0
	    set x1 [expr {$x0+$options(-tile-width)}]
	    set y1 $options(-tile-height)
	    [dict get $data $tile] copy $img -from $x0 $y0 $x1 $y1
	}
    }

    method draw {window id x y sx sy ctags} {
	$window create image $x $y -anchor nw -image [dict get $data $id] -tags $ctags
	return $ctags
    }
    
    method rescale {window num den} {
	set dnum [dict get $data num]
	set dden [dict get $data den]
	if {$den == $dnum} {
	    set dnum $num
	} else {
	    set dnum [expr {$dnum*$num}]
	    set dden [expr {$dden*$den}]
	}
	dict set data num $dnum
	dict set data den $dden
	$tmp blank
	if {$dnum == $dden} {
	    set twid $options(-tile-width)
	    set thgt $options(-tile-height)
	    $tmp copy $img
	} else {
	    set twid [expr {$dnum*$options(-tile-width)/$dden}]
	    set thgt [expr {$dnum*$options(-tile-height)/$dden}]
	    if {[dict get $data noscale]} {
		# this won't work unless tkImgPhoto has my patch in it
		$tmp copy $img -zoom $dnum $dnum -subsample $dden $dden
	    } else {
		# and this won't work unless tkImgPhoto has another patch
		$tmp copy $img -scale [expr {double($dnum)/$dden}]
	    }
	}
	foreach tile $options(-tiles) {
	    set i [dict get $data $tile]
	    set ix [lsearch $options(-tiles) $tile]
	    set x0 [expr {$ix*$twid}]
	    set y0 0
	    set x1 [expr {$x0+$twid}]
	    set y1 $thgt
	    $i blank
	    $i copy $tmp -from $x0 $y0 $x1 $y1
	}
    }
}

set mypng new-tiles-large.png
