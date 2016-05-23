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

package provide mahjong-svg 1.0

package require Tk
package require snit

#
# translate a subset of svg into canvas graphics
# make the <defs></defs> in an svg file available
# for rendering as canvas items, and cache the
# translation
#
snit::type mahjong::svg {
    option -file -default {} -readonly true
    option -data -default {} -readonly true
    
    constructor {args} {
	$self configure {*}$args
	if {$options(-data) ne {}} {
	    $self parse $options(-data)
	} elseif {$options(-file) ne {}} {
	    $self parse [read-file $options(-file)]
	} else {
	    error "svg needs -data or -file option specified"
	}
    }

    #
    # read a whole file
    #
    proc read-file {file} {
	set fp [open $file]
	set d [read $fp]
	close $fp
	return $d
    }
    
    #
    # translate an xml format document into a tcl list
    #
    proc xml2list xml {
	regsub -all {>\s*<} [string trim $xml " \n\t<>"] "\} \{" xml
	set xml [string map {> "\} \{#text \{" < "\}\} \{"}  $xml]
	
	set res ""   ;# string to collect the result   
	set stack {} ;# track open tags
	set rest {}
	
	foreach item "{$xml}" {
	    switch -regexp -- $item {
		^# {
		    append res "{[lrange $item 0 end]} " ; #text item
		}
		^/ {
		    regexp {/(.+)} $item -> tagname ;# end tag
		    set expected [lindex $stack end]
		    if {$tagname!=$expected} {error "$item != $expected"}
		    set stack [lrange $stack 0 end-1]
		    append res "\}\} "
		}
		/$ { # singleton - start and end in one <> group
		    regexp {([^ ]+)( (.+))?/$} $item -> tagname - rest
		    set rest [lrange [string map {= " "} $rest] 0 end]
		    append res "{$tagname [list $rest] {}} "
		}
		^!-- { # comment
		}
		default {
		    set tagname [lindex $item 0] ;# start tag
		    set rest [lrange [string map {= " "} $item] 1 end]
		    lappend stack $tagname
		    append res "\{$tagname [list $rest] \{"
		}
	    }
	    if {[llength $rest]%2} {error "att's not paired: $rest"}
	}
	if [llength $stack] {error "unresolved: $stack"}
	string map {"\} \}" "\}\}"} [lindex $res 0]
    }
    
    variable defs -array {}
    variable targets -array {}
    variable defsid {}
    variable immed {}
    
    #
    # translate the svg defining the mahjong tile set
    # into tk::canvas graphics so the tiles can be 
    # generated at appropriate scale for whatever
    # window is used
    #
    ##
    ## interpret transforms
    ##
    # is a 3 element row vector
    proc is-vector {v} {
	return [tcl::mathop::& [expr {[llength $v]==3}] {*}[lmap vi $v {string is double $vi}]]
    }
    # is a 3x3 matrix
    proc is-matrix {m} {
	return [tcl::mathop::& [expr {[llength $m]==3}] {*}[lmap mi $m {is-vector $mi}]]
    }
    # matrix(a b c d e f) as a matrix
    proc abcdef-to-matrix {abcdef} {
	if {[llength $abcdef] != 6} { error "bad abcdef: $abcdef" }
	foreach {a b c d e f} $abcdef break
	return [list [list $a $c $e] [list $b $d $f] {0 0 1}]
    }
    # scale(x y) as a matrix
    proc scale-to-abcdef {x {y {}}} {
	if {$y eq {}} { set y $x }
	return [list $x 0 0 $y 0 0]
    }
    # translate(x y) as a matrix
    proc translate-to-abcdef {x {y 0}} {
	return [list 1 0 0 1 $x $y]
    }
    proc matrix-from-translate {x {y 0}} {
	return [abcdef-to-matrix [translate-to-abcdef $x $y]]
    }
    proc matrix-from-scale {x {y {}}} {
	return [abcdef-to-matrix [scale-to-abcdef $x $y]]
    }
    # vector dot product between vectors written as rows
    proc vector-dot {v1 v2} {
	return [tcl::mathop::+ {*}[lmap x $v1 y $v2 {expr {$x*$y}}]]
    }
    # matrix transpose, only 3x3
    proc matrix-transpose {m} {
	foreach {r1 r2 r3} $m break
	return [lmap x1 $r1 x2 $r2 x3 $r3 {list $x1 $x2 $x3}]
    }
    # matrix times a matrix, each as a column of rows
    proc matrix-mul-matrix {m1 m2} {
	if { ! [is-matrix $m1]} { error "bad matrix: $m1" }
	if { ! [is-matrix $m2]} { error "bad matrix: $m2" }
	return [ lmap m1i $m1 { lmap m2j [matrix-transpose $m2] {vector-dot $m1i $m2j} }]
    }
    # matrix times a column vector written as a row
    proc matrix-mul-vector {m v} {
	return [ lmap mi $m {vector-dot $mi $v} ]
    }
    # matrix as matrix(a b c d e f)
    proc matrix-to-abcdef {matrix} {
	foreach {r1 r2 r3} $matrix break
	foreach {a c e} $r1 break
	foreach {b d f} $r2 break
	foreach {g h i} $r3 break
	if {$g != 0 || $h != 0 || $i != 1} { error "matrix has an unexpected third row {$matrix}" }
	return [list $a $b $c $d $e $f]
    }
    # 
    proc transform-interpret {tag attrs matrix} {
	# matrix(<a> <b> <c> <d> <e> <f>) -> [[a c e] [b d f] [0 0 1]]
	#	[xp]   [a c e]   [xn]
	#	[yp] = [b d f] * [yn]
	#	[ 1]   [0 0 1]   [ 1]
	# translate(<x> [<y>]) == matrix(1 0 0 1 x y) -> [[1 0 x][0 1 y][0 0 1]]
	#	missing <y> then y == 0
	# scale(<x> [<y>]) == matrix(x 0 0 y 0 0) -> [[x 0 0][0 y 0][0 0 1]]
	#	missing <y> then y == x
	# rotate(<a> [<x> <y>]) matrix(cos(a) sin(a) -sin(a) cos(a) 0 0)
	# skewX(<a>) matrix(1 0 tan(a) 1 0 0)
	# skewY(<a>) matrix(1 tan(a) 0 1 0 0)
	#
	# transform1 transform2 are combined by matrix-mul-matrix $transform1 $transform2 
	# the current transformation matrix is the combination of all transforms defined 
	# and it transforms coordinates in the current user coordinate frame into coordinates
	# in the view port coordinate frame.
	#
	array set a $attrs
	if {[info exists a(transform)]} {
	    set tfm $a(transform)
	    set tfm [string map {{,} { }} $tfm]
	    set tfm [regsub -all {  +} $tfm { }]
	    set tfm [string trim $tfm]
	    while {$tfm ne {}} {
		if {[regexp {([a-zA-Z]+)\(([-0-9. ]+)\)(.*)$} $tfm all op args rest]} {
		    set n [llength $args]
		    switch $op {
			matrix {
			    if {$n != 6} {
				error "bad matrix $tfm"
			    }
			    set matrix2 [abcdef-to-matrix $args]
			    set nmatrix [matrix-mul-matrix $matrix $matrix2]
			    #puts "$matrix * matrix($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			translate {
			    if {$n != 1 && $n != 2} {
				error "bad translate $tfm"
			    }
			    set matrix2 [abcdef-to-matrix [translate-to-abcdef {*}$args]]
			    set nmatrix [matrix-mul-matrix $matrix $matrix2]
			    #puts "$matrix * translate($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			scale {
			    if {$n != 1 && $n != 2} {
				error "bad scale $tfm"
			    }
			    set matrix2 [abcdef-to-matrix [scale-to-abcdef {*}$args]]
			    set nmatrix [matrix-mul-matrix $matrix $matrix2]
			    #puts "$matrix * scale($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			rotate {
			    if {$n < 1 || $n > 3} {
				error "bad rotate $tfm"
			    }
			    set nmatrix [matrix-mul-matrix $matrix [rotate-to-matrix {*}$args]]
			    puts "$matrix * rotate($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			skewX {
			    if {$n != 1} {
				error "bad skewX $tfm"
			    }
			    set nmatrix [matrix-mul-matrix $matrix [skewX-to-matrix {*}$args]]
			    puts "$matrix * skewX($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			skewY {
			    if {$n != 1} {
				error "bad skewY $tfm"
			    }
			    set nmatrix [matrix-mul-matrix $matrix [skewY-to-matrix {*}$args]]
			    puts "$matrix * skewY($args) -> $nmatrix"
			    set matrix $nmatrix
			}
			default {
			    error "unimplemented transform: $tfm"
			}
		    }
		    set tfm [string trim $rest]
		}
	    }
	}
	return $matrix
    }
    #
    # path d
    # lower case relative, upper case absolute
    # m or M = move
    # l or L = line
    # h or H = horizontal line
    # v or V = vertical line
    # c or C = cubic bezier 
    # s or S = short cubic bezier
    # q or Q = quartic bezier 
    # t or T = short quartic bezier
    # z or Z = terminate path
    # a or A = elliptical arc
    # numbers with optional spaces and commas
    #
    
    #
    # this just parses all those wierdly concatenated operands into clean lists
    # the additional interpretations available are:
    #  1) rewrite h dx1 dx2 ... to l dx1 0 dx2 0 ...
    #  2) rewrite v dy1 dy2 ... to l 0 dy1 0 dy2 ...
    #  3) rewrite s dcx dcy dx dy ... into c ... by inserting the mirrored control point
    #	(there are relatively few s operations in the tiles)
    #  4) rewrite l concatenated to c by replicating the knot point as control point
    #  5) rewrite m c* z as a smoothed canvas polygon
    #  6) rewrite m c* (anything but z) as a smoothed canvas line
    #	(there are very few of these in the tiles)
    #
    proc path-parse {d} {
	set n [string length $d]
	set cmds {}
	set op {}
	set num {}
	set nums {}
	for {set i 0} {$i < $n} {incr i} {
	    set c [string index $d $i]
	    if {$c in {h H v V l L m M z Z c C q Q s S t T}} {
		if {$num ne {}} { lappend nums $num; set num {} }
		if {$op ne {}} { lappend cmds [list $op {*}$nums]; set nums {} }
		set op $c; set num {}; set nums {}
	    } elseif {$c eq {-}} { # negative sign, only as first character
		if {$num ne {}} { lappend nums $num; set num {} }
		append num $c
	    } elseif {$c in {0 1 2 3 4 5 6 7 8 9 .}} { # part of a number
		if { ! [string is double $num$c]} { lappend nums $num; set num {} }
		append num $c
	    } elseif {[string first $c ", \t\n"] >= 0} { # comma or space or newline, separator
		if {$num ne {}} { lappend nums $num }
		set num {}
	    } else {
		error "unexpected character {$c} in path.d"
	    }
	}
	if {$num ne {}} { lappend nums $num; set num {} }
	if {$op ne {}} { lappend cmds [list $op {*}$nums]; set nums {} }
	return $cmds
    }
    proc path-check-operands {cmds} {
	foreach cmd $cmds {
	    set n [llength [lrange $cmd 1 end]]
	    switch [lindex $cmd 0] {
		m - M { set test {$n == 2} }
		h - v -
		H - V { set test {$n > 0} }
		l - L { set test {$n > 1 && ($n % 2) == 0} }
		s - S { set test {$n > 3 && ($n % 4) == 0} }
		c - C { set test {$n > 5 && ($n % 6) == 0} }
		z - Z { set test {$n == 0} }
		default {
		    error "unexpected command: $cmd"
		}
	    }
	    if { ! [expr $test]} {
		error "wrong number of arguments for: $cmd"
	    }
	}
	return $cmds
    }
    proc path-expand {cmds} {
	
	# translate from abbreviated commands to cubic beziers
	set lop {}
	set lxy {}
	set results {}
	foreach cmd $cmds {
	    set op [lindex $cmd 0]
	    set nresult [lrange $cmd 1 end]; # $result
	    while {1} {
		set result $nresult
		set nresult {}
		switch $op {
		    h { 
			foreach dx $result { lappend nresult $dx 0 }
			set op l
			continue
		    }
		    v {
			foreach dy $result { lappend nresult 0 $dy }
			set op l
			continue
		    }
		    l {
			# it seems that if the desired result is that the desired result
			# is a line from the last point of a cubic bezier, then the last
			# point in the bezier needs to be tripled, too, but because it's
			# relative coordinates, that will be 0 0 0 0 0 0.
			if {$lop eq {c}} { lappend nresult 0 0 0 0 0 0 }
			foreach {dx dy} $result { lappend nresult $dx $dy $dx $dy $dx $dy }
			set op c
			continue
		    }
		    s {
			# this is simplified by the change of coordinate frame.
			# ldc2x ldc2y and ldx ldy are specified relative to llx lly
			# so we can mirror ldcx ldcy through ldx ldy by subtraction,
			# oops, so the prior control point to be mirrored might be
			# in the c string immediately preceding this s string.
			if {$lop eq {c}} {
			    foreach {dc2x dc2y dx dy} [lrange $lxy end-3 end] break
			} elseif {$lop eq {m}} {
			    foreach {dc2x dc2y dx dy} [concat $lxy $lxy] break
			} else {
			    error "unexpected predecessor $lop to s in ..."
			}
			set dc1x [expr {$dx-$dc2x}]
			set dc1y [expr {$dy-$dc2y}]
			foreach {dc2x dc2y dx dy} $result {
			    lappend nresult $dc1x $dc1y $dc2x $dc2y $dx $dy
			    # compute next dc1x and dc1y
			    set dc1x [expr {$dx-$dc2x}]
			    set dc1y [expr {$dy-$dc2y}]
			}
			set op c
			continue
		    }
		    z {
			# close path, hmm, so the path ends c1 c2 k, 
			# but the k should be the same as the m that 
			# that started the path?  Looks like it usually
			# is the m that started the path
			# if {$lop eq {c} && $llop eq {m}} {
			#}
			break
		    }
		    m {
			# in a multi part path, this needs to be relative to
			# to the end of the previous path part, but maybe
			# that happens when we translate to coords from deltas.
		    }
		    c {
			break
		    }
		}
		break
	    }
	    if {$lop eq $op} {
		set lxy [list {*}$lxy {*}$result]
		set results [lreplace $results end end [list $lop {*}$lxy]]
	    } else {
		set lop $op
		set lxy $result
		lappend results [list $op {*}$lxy]
	    }
	    
	}
	return $results
    }
    proc path-translate-xy {xname yname cmd m c} {
	upvar $xname x
	upvar $yname y
	switch $cmd {
	    mc - mcz {
		foreach {dx dy} [lrange $m 1 end] break
		set x [expr {$x+$dx}]
		set y [expr {$y+$dy}]
		lappend cmd $x $y
		foreach {dc1x dc1y dc2x dc2y dx dy} [lrange $c 1 end] {
		    set c1x [expr {$x+$dc1x}]
		    set c1y [expr {$y+$dc1y}]
		    set c2x [expr {$x+$dc2x}]
		    set c2y [expr {$y+$dc2y}]
		    set nx [expr {$x+$dx}]
		    set ny [expr {$y+$dy}]
		    lappend cmd $c1x $c1y $c2x $c2y $nx $ny
		    set x $nx
		    set y $ny
		}
	    }
	    ML {
		foreach {x y} [lrange $m 1 end] break
		lappend cmd $x $y
		foreach {x y} [lrange $c 1 end] {
		    lappend cmd $x $y
		}
	    }
	    default {
		error "unknown cmd {$cmd} in path-translate-xy"
	    }
	}
	return $cmd
    }
    proc path-translate {results} {
	#
	# concatenate mcz and mc into canvas polygon and line items
	# translate from relative to absolute coordinates
	#
	# puts "path d [join [lmap r $results {lindex $r 0}] {}]"
	set cmds {}
	set type [join [lmap r $results {lindex $r 0}] {}];
	set x 0
	set y 0
	while {[llength $results] > 0} {
	    switch -glob $type {
		mcz* {
		    lappend cmds [path-translate-xy x y {mcz} [lindex $results 0] [lindex $results 1]]
		    set results [lrange $results 3 end]
		    set type [string range $type 3 end]
		}
		mc* {
		    lappend cmds [path-translate-xy x y {mc} [lindex $results 0] [lindex $results 1]]
		    set results [lrange $results 2 end]
		    set type [string range $type 2 end]
		}
		ML* {
		    lappend cmds [path-translate-xy x y {ML} [lindex $results 0] [lindex $results 1]]
		    set results [lrange $results 2 end]
		    set type [string range $type 2 end]
		}
		default {
		    error "unexpected type $type"
		}
	    }
	}
	return $cmds
    }
    proc path-interpret {d} {
	set cmds [path-parse $d]
	set cmds [path-check-operands $cmds]
	set cmds [path-expand $cmds]
	return [path-translate $cmds]
    }
    #
    # item generators
    # oh, got the defs/use wrong
    # need to do the translation 
    # at the time of the call so
    # that parameters supplied to
    # the use can be expanded in
    # the call.
    #
    method generate-emit {window matrix code ctags} {
	if {[$self in-defs $ctags]} {
	    # set id [lindex $ctags $i+1]
	    # puts "$ctags implies definition of $id"
	    # lappend defs($id) [list $matrix $code]
	} else {
	    # puts "$ctags implies immediate code"
	    lappend immed [list $matrix $code]
	}
    }
    method generate-frag-finish {window matrix frag ctags} {
	if {[lsearch $frag -width] >= 0} { lappend ctags scale-width }
	lappend frag -tags $ctags
	$self generate-emit $window $matrix $frag $ctags
    }
    method generate-line-finish {window matrix frag fill stroke stroke-width ctags} {
	if {$stroke ne {}} { lappend frag -fill $stroke }
	if {${stroke-width} ne {}} { lappend frag -width ${stroke-width} }
	$self generate-frag-finish $window $matrix $frag $ctags
    }
    method generate-poly-finish {window matrix frag fill stroke stroke-width ctags} {
	if {$fill eq {none}} { set fill {} }
	lappend frag -fill $fill
	if {$stroke ne {}} { lappend frag -outline $stroke }
	if {${stroke-width} ne {}} { lappend frag -width ${stroke-width} }
	$self generate-frag-finish $window $matrix $frag $ctags
    }
    method generate-path {window matrix d fill stroke stroke-width ctags} {
	foreach cmd [path-interpret $d] {
	    set op [lindex $cmd 0]
	    set coords [lrange $cmd 1 end]
	    switch $op {
		mcz { $self generate-poly-finish $window $matrix [list $window create polygon {*}$coords -smooth raw] $fill $stroke ${stroke-width} $ctags }
		mc { $self generate-line-finish $window $matrix [list $window create line {*}$coords -smooth raw] $fill $stroke ${stroke-width} $ctags }
		ML { $self generate-line-finish $window $matrix [list $window create line {*}$coords] $fill $stroke ${stroke-width} $ctags }
		default { error "unknown op $op" }
	    }
	}
    }
    method generate-polygon {window matrix points fill stroke stroke-width ctags} {
	set frag [list $window create polygon {*}$points]
	$self generate-poly-finish $window $matrix $frag $fill $stroke ${stroke-width} $ctags
    }
    method generate-line {window matrix x1 y1 x2 y2 fill stroke stroke-width ctags} {
	set frag [list $window create line $x1 $y1 $x2 $y2]
	$self generate-line-finish $window $matrix $frag $fill $stroke ${stroke-width} $ctags
    }
    method generate-rect {window matrix x y width height fill stroke stroke-width ctags} {
	set frag [list $window create rectangle $x $y [expr {$x+$width}] [expr {$y+$height}]]
	$self generate-poly-finish $window $matrix $frag $fill $stroke ${stroke-width} $ctags
    }
    method generate-circle {window matrix cx cy r fill stroke stroke-width ctags} {
	set frag [list $window create oval [expr {$cx-$r}] [expr {$cy-$r}] [expr {$cx+$r}] [expr {$cy+$r}]]
	$self generate-poly-finish $window $matrix $frag $fill $stroke ${stroke-width} $ctags
    }
    method generate-ellipse {window matrix cx cy rx ry fill stroke stroke-width ctags} {
	set frag [list $window create oval [expr {$cx-$rx}] [expr {$cy-$ry}] [expr {$cx+$rx}] [expr {$cy+$ry}]]
	$self generate-poly-finish $window $matrix $frag $fill $stroke ${stroke-width} $ctags
    }
    method generate-use {window matrix pattrs id ctags} {
	# puts "use $matrix $id $ctags :: $defs($id)"
	if {[$self in-defs $ctags]} {
	    # when in defs section ignore the translation
	} else {
	    # regenerate the code 
	    # puts "use $id -> $defs($id)"
	    foreach {indent c m p tag attrs body} $defs($id) break
	    set pattrs [concat $p $pattrs]
	    set ctags [list {*}$c {*}$ctags]
	    $self element-traverse-one $window $indent $ctags $matrix $pattrs $tag $attrs $body
	}
    }

    #
    # checkers
    #
    variable tags -array {
	svg {
	    ignore-all false
	    can-be-def false
	    require {height width viewBox} ignore {id xmlns:rdf xmlns version xmlns:cc xmlns:xlink xmlns:dc}
	    body-empty false
	}
	metadata {
	    ignore-all false
	    can-be-def false
	    ignore {id}
	    body-empty false
	}
	rdf:RDF	{
	    ignore-all false
	    can-be-def false
	    body-empty false
	}
	cc:Work {
	    ignore-all false
	    can-be-def false
	    ignore rdf:about
	    body-empty false
	}
	dc:format {
	    ignore-all false
	    can-be-def false
	    body-empty false
	}
	\#text {
	    ignore-all true
	}
	dc:type {
	    ignore-all false
	    can-be-def false
	    ignore {rdf:resource}
	    body-empty false
	}
	defs {
	    ignore-all false
	    can-be-def false
	    ignore {id}
	    body-empty false
	}
	g {
	    ignore-all false
	    can-be-def true
	    permit {transform style stroke stroke-width fill x y} ignore {id}
	    body-empty false
	    attr-filler {fill {} stroke {} stroke-width {}}
	}
	path {
	    ignore-all false
	    can-be-def true
	    require {d} permit {id fill stroke stroke-width style}
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	}
	polygon {
	    ignore-all false
	    can-be-def true
	    require {points} permit {stroke stroke-width fill} ignore {id}
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	}
	line {
	    ignore-all false
	    can-be-def true
	    require {x1 y1 x2 y2} permit {fill stroke stroke-width} ignore {id}
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	}
	rect {
	    ignore-all false
	    can-be-def true
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	    require {x y width height} permit {stroke stroke-width fill} ignore {id}
	}
	circle {
	    ignore-all false
	    can-be-def true
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	    require {cx cy r} permit {stroke stroke-width fill} ignore {id}
	}
	ellipse {
	    ignore-all false
	    can-be-def true
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	    require {cx cy rx ry} permit {stroke stroke-width fill} ignore {id}
	}
	use {
	    ignore-all false
	    can-be-def true
	    body-empty true
	    attr-filler {fill {} stroke {} stroke-width {}}
	    require {xlink:href} permit {transform style fill stroke stroke-width x y} ignore {id}
	}
    }
    
    method tag-test {tag test} {
	array set info $tags($tag)
	return $info($test)
    }
    method ignore-all {tag} {
	return [$self tag-test $tag ignore-all]
    }
    method can-be-def {tag} {
	return [$self tag-test $tag can-be-def]
    }
    method attr-check {tag attributes} {
	array set info $tags($tag)
	array set b $attributes
	set missing {}
	foreach treatment {require permit ignore} {
	    if { ! [info exists info($treatment)]} continue
	    set attrs $info($treatment)
	    foreach attr $attrs { 
		set e [info exists b($attr)]
		switch $treatment {
		    require { if {$e} { unset b($attr) } else { lappend missing $attr } }
		    permit { if {$e} { unset b($attr) } }
		    ignore { if {$e} { unset b($attr) } }
		    default { error "unknown attribute treatment: $treatment" }
		}
	    }
	}
	set leftovers [array names b]
	if {$missing ne {} || $leftovers ne {}} {
	    error "attr-check $tag leftovers {$leftovers} missing {$missing}"
	}
    }
    proc attr-filter {attrs} {
	set fattrs {}
	foreach {name value} $attrs {
	    if {$name in {fill stroke stroke-width}} {
		lappend fattrs $name $value
	    }
	}
	return $fattrs
    }
    method body-empty {tag body} {
	if {[$self tag-test $tag body-empty] && $body ne {}} { 
	    error "$tag body is not empty {$body}"
	}
    }
    method interesting-id {tag attrs} {
	array set a $attrs
	if { ! [info exists a(id)]} { return 0 }
	set id $a(id)
	if {[regexp ^$tag\\d+$ $id]} {
	    #puts "$tag id=$id is uninteresting"
	    return 0
	}
	if {$tag eq {path} && [regexp ^circle\\d+$ $id]} {
	    #puts "$tag id=$id is uninteresting"
	    return 0
	}
	if {[info exists targets($id)]} {
	    error "$tag $id already defined as $targets($id)"
	}
	#puts "saving $tag $id"
	set targets($id) $tag
	return 1
    }
    method interesting-target {tag attrs} {
	array set a $attrs
	if { ! [info exists a(xlink:href)]} { error "$tag has no href attribute" }
	set href $a(xlink:href)
	if {[string first \# $href] != 0} { error "$tag href $href does not start with #" }
	set href [string range $href 1 end]
	if { ! [info exists targets($href)]} { error "$tag href $href is not defined" }
	return $href
    }
    proc unpack-style {tag attrs} {
	array set a $attrs
	if {[info exists a(style)]} {
	    switch -regexp $a(style) {
		fill:#[0-9a-f]+ { return [list fill [string range $a(style) 5 end]] }
		stroke:#[0-9a-f]+ { return [list stroke [string range $a(style) 7 end]] }
		default { error "$tag unhandled style $a(style)" }
	    }
	}
	return {}
    }
    method build-attrs {tag attrs pattrs} {
	array set info $tags($tag)
	if {[info exists info(attr-filler)]} {
	    array set a [concat $info(attr-filler) $pattrs $attrs]
	    array set a [unpack-style $tag $attrs]
	} else {
	    array set a [concat $pattrs $attrs]
	}
	return [array get a]
    }
    
    proc lremove {list item} {
	set i [lsearch $list $item]
	if {$i >= 0} {
	    set list [lreplace $list $i $i]
	}
	return $list
    }

    method in-defs {ctags} {
	return [expr {$defsid ne {} && [lsearch $ctags $defsid] >= 0}]
    }
    
    # traverse a document tree $doc
    # using $indent as an indentation string
    # and $ctags as the inherited canvas tags
    # and $pattrs as the inherited attributes
    method element-traverse {window indent ctags matrix pattrs doc} {
	foreach {tag attrs body} $doc {
	    $self element-traverse-one $window $indent $ctags $matrix $pattrs $tag $attrs $body
	}
    }
    method element-traverse-one {window indent ctags matrix pattrs tag attrs body} {
	#element-setup $tag $attrs $body
	# if {$indent in {{} { } {  }}} { puts stdout "$indent$tag $attrs" }
	if {[$self ignore-all $tag]} return
	$self attr-check $tag $attrs
	$self body-empty $tag $body
	array set a [$self build-attrs $tag $attrs $pattrs]
	if {[info exists a(id)] && $a(id) ni $ctags} { lappend ctags $a(id) }
	if {[$self can-be-def $tag] && [$self in-defs $ctags] && [$self interesting-id $tag $attrs]} {
	    set defs($a(id)) [list $indent [lremove $ctags $defsid] $matrix $pattrs $tag $attrs $body]
	}
	switch $tag {
	    svg -
	    metadata -
	    rdf:RDF -
	    cc:Work -
	    dc:format -
	    dc:type {}
	    defs { 
		set defsid $a(id)
	    }
	    g {
		set matrix [transform-interpret $tag $attrs $matrix]
		set pattrs [attr-filter [array get a]]
	    }
	    path {
		$self generate-path $window $matrix $a(d) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    polygon {
		$self generate-polygon $window $matrix $a(points) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    line {
		$self generate-line $window $matrix $a(x1) $a(y1) $a(x2) $a(y2) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    rect {
		$self generate-rect $window $matrix $a(x) $a(y) $a(width) $a(height) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    circle {
		$self generate-circle $window $matrix $a(cx) $a(cy) $a(r) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    ellipse {
		$self generate-ellipse $window $matrix $a(cx) $a(cy) $a(rx) $a(ry) $a(fill) $a(stroke) $a(stroke-width) $ctags
	    }
	    use {
		# call definition
		set x 0; if {[info exists a(x)]} { set x $a(x) }
		set y 0; if {[info exists a(y)]} { set y $a(y) }
		set matrix [transform-interpret $tag $attrs $matrix]
		if {$x != 0 || $y != 0} {
		    set matrix [matrix-mul-matrix $matrix [matrix-from-translate $x $y] ]
		}
		set id [$self interesting-target $tag $attrs]
		$self generate-use $window $matrix [attr-filter [array get a]] $id $ctags
	    }
	    default {
		puts stderr "missing tag $tag"
	    }
	}
	foreach item $body { $self element-traverse $window "$indent " $ctags $matrix $pattrs $item }
    }

    #
    # parse an svg document
    #
    method parse {doc} {
	$self element-traverse .svg {} {} [abcdef-to-matrix {1 0 0 1 0 0}] {} [xml2list $doc] 
    }
    method defs {{pattern *}} {
	return [array names defs $pattern]
    }
    variable cache -array {}
    method draw-cache {window svgid ctags} {
	foreach record $cache($svgid) {
	    foreach {matrix code} $record break
	    set abcdef [matrix-to-abcdef $matrix]
	    set cid [{*}$code]
	    # puts "$cid <- $code"
	    set xscale [lindex $abcdef 0]
	    set yscale [lindex $abcdef 3]
	    set xmove [lindex $abcdef 4]
	    set ymove [lindex $abcdef 5]
	    $window scale $cid 0 0 $xscale $yscale
	    $window move $cid $xmove $ymove
	    foreach t $ctags { $window addtag $t withtag $cid }
	    if {[lsearch [$window itemcget $cid -tags] scale-width] >= 0} {
		set width [$window itemcget $cid -width]
		$window itemconfigure $cid -width [expr {$xscale*$width}]
		# puts "$cid [$window itemcget $cid -tags] $width -> [expr {$xscale*$width}]"
	    }
	}	
    }
    method draw {window svgid x y sx sy ctags} {
	if { ! [info exists cache($svgid)]} {
	    set immed {}
	    set matrix [matrix-mul-matrix [matrix-from-translate $x $y] [matrix-from-scale $sx $sy]]
	    $self generate-use $window $matrix {} $svgid {}
	    set cache($svgid) $immed
	    # puts "drawing tiles at scale $sx $sy"
	}
	$self draw-cache $window $svgid $ctags
	return $ctags
    }
    method rescale {window num den} {
    }
}

set mysvg {<svg id="svg3455" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://www.w3.org/2000/svg" height="88" width="2816" version="1.1" xmlns:cc="http://creativecommons.org/ns#" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 2816 88" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata id="metadata4483">
    <rdf:RDF>
      <cc:Work rdf:about="">
	<dc:format>image/svg+xml</dc:format>
	<dc:type rdf:resource="http://purl.org/dc/dcmitype/StillImage"/>
      </cc:Work>
    </rdf:RDF>
  </metadata>
  <defs id="defs3457">
    <!-- tiles -->
    <g id="plain-tile">
      <path id="path3460" d="m9 0c-0.53 0-1.04 0.21-1.41 0.59l-7 7c-0.38 0.37-0.59 0.88-0.59 1.41v77c0 1.1 0.9 2 2 2h53c0.53 0 1.04-0.21 1.41-0.59l7-7c0.38-0.37 0.59-0.88 0.59-1.41v-77c0-1.1-0.9-2-2-2h-53z" fill="#000000"/>
      <path id="path3462" d="m11.75 78.25l-9 9h52.25c0.33 0 0.65-0.13 0.88-0.37l7-7c0.23-0.23 0.37-1.3 0.37-1.63h-51.5z" fill="#9F9F9F"/>
      <path id="path3464" d="m8.12 1.12l-7 7c-0.24 0.23-0.37 0.55-0.37 0.88v76.25l2 2 7-7v-79.5c-0.33 0-1.4 0.13-1.63 0.37z" fill="#D7D7D7"/>
      <path id="path3466" d="m1.61 86.89l10.14-10.14v-0.5l-10.41 10.41c0.08 0.09 0.17 0.16 0.27 0.23z" fill="#BFBFBF"/>
      <path id="path3468" d="m1.93 87.07l9.82-9.82v-0.5l-10.14 10.14c0.1 0.07 0.21 0.13 0.32 0.18z" fill="#B7B7B7"/>
      <path id="path3470" d="m2.3 87.2l9.45-9.45v-0.5l-9.82 9.82c0.12 0.05 0.24 0.1 0.37 0.13z" fill="#AFAFAF"/>
      <path id="path3472" d="m11.75 77.75l-9.45 9.45c0.14 0.03 0.29 0.05 0.45 0.05l9-9v-0.5z" fill="#A7A7A7"/>
      <path id="path3474" d="m1.34 86.66l10.41-10.41h-0.5l-10.14 10.14c0.07 0.1 0.14 0.19 0.23 0.27z" fill="#C7C7C7"/>
      <path id="path3476" d="m1.11 86.39l10.14-10.14h-0.5l-9.82 9.82c0.05 0.11 0.11 0.22 0.18 0.32z" fill="#CDCDCD"/>
      <path id="path3478" d="m0.93 86.07l9.82-9.82h-0.5l-9.45 9.45c0.03 0.13 0.08 0.25 0.13 0.37z" fill="#D2D2D2"/>
      <path id="path3480" d="m10.25 76.25h-0.5l-9 9c0 0.15 0.02 0.3 0.05 0.45l9.45-9.45z" fill="#D7D7D7"/>
      <path id="path3482" d="m63.25 78.25v-75.5c0-1.1-0.9-2-2-2h-50.5c-1.1 0-2 0.9-2 2v75.5c0 1.1 0.9 2 2 2h50.5c1.1 0 2-0.9 2-2z" fill="#F6F6F6"/>
      <path id="path3484" d="m8.75 78.25v-75.5c0-1.1 0.9-2 2-2h-1c-1.1 0-2 0.9-2 2v75.5c0 1.1 0.9 2 2 2h1c-1.1 0-2-0.9-2-2z" fill="#fff"/>
    </g>
    <g id="selected-tile">
      <path id="path3487" d="m9 0c-0.53 0-1.04 0.21-1.41 0.59l-7 7c-0.38 0.37-0.59 0.88-0.59 1.41v77c0 1.1 0.9 2 2 2h53c0.53 0 1.04-0.21 1.41-0.59l7-7c0.38-0.37 0.59-0.88 0.59-1.41v-77c0-1.1-0.9-2-2-2h-53z" fill="#00f"/>
      <path id="path3489" d="m11.75 78.25l-9 9h52.25c0.33 0 0.65-0.13 0.88-0.37l7-7c0.23-0.23 0.37-1.3 0.37-1.63h-51.5z" fill="#8F8FFF"/>
      <path id="path3491" d="m8.12 1.12l-7 7c-0.24 0.23-0.37 0.55-0.37 0.88v76.25l2 2 7-7v-79.5c-0.33 0-1.4 0.13-1.63 0.37z" fill="#C7C7FF"/>
      <path id="path3493" d="m1.61 86.89l10.14-10.14v-0.5l-10.41 10.41c0.08 0.09 0.17 0.16 0.27 0.23z" fill="#AFAFFF"/>
      <path id="path3495" d="m1.93 87.07l9.82-9.82v-0.5l-10.14 10.14c0.1 0.07 0.21 0.13 0.32 0.18z" fill="#A7A7FF"/>
      <path id="path3497" d="m2.3 87.2l9.45-9.45v-0.5l-9.82 9.82c0.12 0.05 0.24 0.1 0.37 0.13z" fill="#9F9FFF"/>
      <path id="path3499" d="m11.75 77.75l-9.45 9.45c0.14 0.03 0.29 0.05 0.45 0.05l9-9v-0.5z" fill="#9797FF"/>
      <path id="path3501" d="m1.34 86.66l10.41-10.41h-0.5l-10.14 10.14c0.07 0.1 0.14 0.19 0.23 0.27z" fill="#B7B7FF"/>
      <path id="path3503" d="m1.11 86.39l10.14-10.14h-0.5l-9.82 9.82c0.05 0.11 0.11 0.22 0.18 0.32z" fill="#BDBDFF"/>
      <path id="path3505" d="m0.93 86.07l9.82-9.82h-0.5l-9.45 9.45c0.03 0.13 0.08 0.25 0.13 0.37z" fill="#C2C2FF"/>
      <path id="path3507" d="m10.25 76.25h-0.5l-9 9c0 0.15 0.02 0.3 0.05 0.45l9.45-9.45z" fill="#C7C7FF"/>
      <path id="path3509" d="m61.25 0.75h-51.5c-1.1 0-2 0.9-2 2v75.5c0 1.1 0.9 2 2 2h51.5c1.1 0 2-0.9 2-2v-75.5c0-1.1-0.9-2-2-2z" fill="#E3E3FF"/>
      <path id="path3511" stroke="#00f" stroke-width="3" d="m60 74.19c0 1.55-1.22 2.81-2.72 2.81h-43.56c-1.5 0-2.72-1.26-2.72-2.81v-67.38c0-1.55 1.22-2.81 2.72-2.81h43.56c1.5 0 2.72 1.26 2.72 2.81v67.38z" fill="#fff"/>
    </g>
    <!-- bamboos -->
    <path id="bamboo" fill="none" stroke-width="1.75" d="m 5.50,12.50 c  1.50,0.00 4.00,-0.50 4.00,1.00  0.00,1.50 -2.50,1.00 -4.00,1.00  -1.50,0.00 -4.00,0.50 -4.00,-1.00  0.00,-1.50 2.50,-1.00 4.00,-1.00 z  m 0.00,-11.00 c  1.50,0.00 4.00,-0.50 4.00,1.00  0.00,1.50 -2.50,1.00 -4.00,1.00  -1.50,0.00 -4.00,0.50 -4.00,-1.00  0.00,-1.50 2.50,-1.00 4.00,-1.00 z  m 0.00,22.00 c  1.50,0.00 4.00,-0.50 4.00,1.00  0.00,1.50 -2.50,1.00 -4.00,1.00  -1.50,0.00 -4.00,0.50 -4.00,-1.00  0.00,-1.50 2.50,-1.00 4.00,-1.00 z  m -2.00,-20.00 l 0.00,9.00 m 4.00,-9.00 l 0.00,9.00 m -4.00,2.00 l 0.00,9.00 m 4.00,-9.00 l 0.00,9.00"/>
    <path id="bamboo-rgt" fill="none" stroke-width="1.75" d="m 5.87,12.57 c  1.39,0.56 3.90,1.03 3.33,2.43  -0.56,1.39 -2.69,-0.01 -4.08,-0.57  -1.39,-0.56 -3.90,-1.03 -3.33,-2.43  0.56,-1.39 2.69,0.01 4.08,0.57 z  m 4.12,-10.20 c  1.39,0.56 3.90,1.03 3.33,2.43  -0.56,1.39 -2.69,-0.01 -4.08,-0.57  -1.39,-0.56 -3.90,-1.03 -3.33,-2.43  0.56,-1.39 2.69,0.01 4.08,0.57 z  m -8.24,20.40 c  1.39,0.56 3.90,1.03 3.33,2.43  -0.56,1.39 -2.69,-0.01 -4.08,-0.57  -1.39,-0.56 -3.90,-1.03 -3.33,-2.43  0.56,-1.39 2.69,0.01 4.08,0.57 z  m 5.64,-19.29 l -3.37,8.34 m 7.08,-6.85 l -3.37,8.34 m -4.46,0.36 l -3.37,8.34 m 7.08,-6.85 l -3.37,8.34"/>
    <path id="bamboo-lft" fill="none" stroke-width="1.75" d="m 5.13,12.57 c  1.39,-0.56 3.52,-1.96 4.08,-0.57  0.56,1.39 -1.94,1.86 -3.33,2.43  -1.39,0.56 -3.52,1.96 -4.08,0.57  -0.56,-1.39 1.94,-1.86 3.33,-2.43 z  m -4.12,-10.20 c  1.39,-0.56 3.52,-1.96 4.08,-0.57  0.56,1.39 -1.94,1.86 -3.33,2.43  -1.39,0.56 -3.52,1.96 -4.08,0.57  -0.56,-1.39 1.94,-1.86 3.33,-2.43 z  m 8.24,20.40 c  1.39,-0.56 3.52,-1.96 4.08,-0.57  0.56,1.39 -1.94,1.86 -3.33,2.43  -1.39,0.56 -3.52,1.96 -4.08,0.57  -0.56,-1.39 1.94,-1.86 3.33,-2.43 z  m -9.35,-17.79 l 3.37,8.34 m 0.34,-9.84 l 3.37,8.34 m -2.96,3.35 l 3.37,8.34 m 0.34,-9.84 l 3.37,8.34"/>
    <!-- coins -->
    <g id="coin" fill="none">
      <circle cx="9.0" cy="9.0" r="8.50" stroke-width="1.3"/>
      <circle cx="9.0" cy="9.0" r="7.20" stroke-width="1.2"/>
      <circle cx="9.0" cy="9.0" r="5.15" stroke-width="1.1"/>
      <circle cx="12.6" cy="9.0" r="3.6" stroke-width="1.0"/>
      <circle cx="9.0" cy="12.6" r="3.6" stroke-width="1.0"/>
      <circle cx="5.4" cy="9.0" r="3.6" stroke-width="1.0"/>
      <circle cx="9.0" cy="5.4" r="3.6" stroke-width="1.0"/>
    </g>
    <!-- characters -->
    <g id="ten-thousand" fill="#BA0000">
      <path id="path3431" d="m 41.6,72.0384 c -1.2925,-1.6198 -2.4244,-3.0449 -2.5153,-3.167 -0.1561,-0.2096 -0.1527,-0.2377 0.061,-0.506 l 0.2265,-0.284 1.8388,0.8983 c 1.0113,0.4941 2.1883,1.0221 2.6155,1.1733 0.7605,0.2693 0.7809,0.2711 0.9829,0.088 0.412,-0.3728 1.1899,-1.6656 1.3877,-2.3062 0.2793,-0.9041 0.2705,-1.8582 -0.022,-2.4389 -0.2676,-0.5306 -0.6449,-0.7431 -1.575,-0.8869 -0.7755,-0.1198 -3.5996,-0.3431 -3.6538,-0.2888 -0.021,0.021 0.5676,0.7674 1.308,1.6588 0.7403,0.8914 1.3261,1.6207 1.3017,1.6207 -0.024,0 -0.9763,-0.3584 -2.1154,-0.7965 -1.139,-0.4381 -2.1032,-0.7766 -2.1425,-0.7523 -0.039,0.024 -1.2481,0.4469 -2.6861,0.939 l -2.6145,0.8948 -0.1487,-0.2875 c -0.082,-0.1582 -0.1487,-0.3299 -0.1487,-0.3816 0,-0.052 0.765,-0.7392 1.7,-1.5276 0.935,-0.7884 1.7,-1.4614 1.7,-1.4955 0,-0.034 -1.3613,-0.092 -3.025,-0.1288 -1.6638,-0.037 -3.8304,-0.096 -4.8147,-0.1312 l -1.7897,-0.064 0.068,0.5908 c 0.037,0.3249 0.2154,1.7948 0.3957,3.2664 l 0.3279,2.6755 -0.3504,0.097 c -0.1927,0.053 -0.3688,0.078 -0.3913,0.056 -0.022,-0.023 -0.6176,-1.54 -1.3225,-3.3723 l -1.2815,-3.3313 -0.4831,-0.032 c -0.7553,-0.049 -2.6068,0.153 -3.4332,0.3752 -0.4125,0.1109 -0.8175,0.202 -0.9,0.2025 -0.1586,0 -1.0605,-1.569 -0.9594,-1.6701 0.032,-0.032 2.2404,-0.2455 4.9077,-0.4744 2.6673,-0.229 4.877,-0.4437 4.9104,-0.4771 0.033,-0.033 -0.033,-0.5926 -0.1473,-1.2427 -0.4706,-2.6738 -0.7386,-5.511 -0.5803,-6.1425 0.055,-0.22 0.1017,-0.2365 0.5748,-0.2041 0.4907,0.034 2.5941,-0.1399 3.0691,-0.2533 0.2177,-0.052 0.225,-0.03 0.225,0.6758 0,0.4012 -0.063,1.0023 -0.1399,1.3358 -0.077,0.3335 -0.2139,1.2364 -0.3043,2.0064 -0.203,1.7282 -0.1989,1.7019 -0.4411,2.7998 -0.1092,0.4948 -0.1909,0.9055 -0.1816,0.9125 0.014,0.011 4.0582,-0.3371 4.1439,-0.3563 0.015,-0 0.02,-1.5022 0.011,-3.331 -0.012,-2.5777 0.016,-3.4599 0.1269,-3.925 l 0.1428,-0.6 0.628,-0.085 c 0.3455,-0.046 0.6559,-0.057 0.6898,-0.023 0.034,0.034 0.05,1.8154 0.037,3.9589 l -0.025,3.8972 0.7813,-0.062 c 0.4296,-0.034 1.0512,-0.09 1.3812,-0.1243 l 0.6,-0.062 0.068,-0.45 c 0.037,-0.2475 0.071,-0.765 0.075,-1.15 0.01,-0.6684 0.1145,-1.2668 0.3036,-1.7 0.1229,-0.2814 0.1975,-0.8221 0.2983,-2.1631 0.05,-0.6669 0.1511,-1.2859 0.2365,-1.4511 0.082,-0.1585 0.1801,-0.5351 0.2181,-0.8369 0.038,-0.3019 0.076,-0.5567 0.085,-0.5663 0.032,-0.034 1.8191,-0.332 1.9953,-0.3323 0.1696,0 2.1696,1.8458 2.1696,2.0027 0,0.04 -0.1365,0.1293 -0.3034,0.1984 -0.6061,0.2511 -1.3577,1.3246 -2.4428,3.4892 -0.6667,1.3301 -1.2708,2.7257 -1.2073,2.7892 0.03,0.03 1.01,-0.022 2.1787,-0.1141 2.7218,-0.2151 3.4146,-0.2115 3.9248,0.021 0.5962,0.2714 1.6753,1.1788 3.8779,3.2608 l 1.978,1.8697 -0.2222,0.3666 c -2.5483,4.2055 -5.7626,7.69 -7.8357,8.4946 -1.0336,0.4011 -0.7316,0.6392 -3.348,-2.6397 z m -10.6598,-19.7074 c -0.1666,-0.2095 -0.3337,-0.4327 -0.3712,-0.4959 -0.042,-0.071 0.2081,-0.2873 0.6564,-0.567 3.8456,-2.3997 6.7832,-6.0572 6.1267,-7.6284 l -0.1451,-0.3473 -0.4285,0.2179 c -2.3749,1.2076 -4.3017,3.6983 -4.8122,6.2205 -0.1189,0.5873 -0.1402,0.6192 -0.4146,0.6192 l -0.2892,0 -1.0783,-4.3 c -0.5931,-2.365 -1.0797,-4.3278 -1.0813,-4.3618 -0,-0.034 0.7058,0.6509 1.5721,1.5219 l 1.575,1.5837 2.4,-1.8413 c 1.32,-1.0127 2.4587,-1.8438 2.5305,-1.8469 0.1611,-0.01 5.2195,3.5762 5.2195,3.6972 0,0.048 -0.063,0.1232 -0.1398,0.1672 -0.6376,0.3649 -4.1602,3.8503 -4.1602,4.1163 0,0.047 0.3487,0.1091 0.775,0.1384 1.0054,0.069 2.1722,0.4648 3.1529,1.0692 l 0.7779,0.4794 -1.8279,0.053 c -2.6758,0.078 -4.8196,0.49 -9.5813,1.842 -0.091,0.026 -0.2762,-0.1109 -0.4564,-0.3375 z"/>
      <path id="path3410" d="m 28.8519,60.7708 c -0.021,-0.066 -0.102,-0.5146 -0.1796,-0.9958 l -0.141,-0.875 0.3093,-0.015 c 0.1702,-0.01 0.4444,-0.027 0.6094,-0.042 0.165,-0.015 0.525,-0.045 0.8,-0.068 1.8965,-0.1589 4.1942,-0.3898 4.7,-0.4724 0.33,-0.054 0.8925,-0.1186 1.25,-0.1438 0.3575,-0.025 1.145,-0.1191 1.75,-0.2085 1.3891,-0.2053 4.3508,-0.4298 4.4099,-0.3342 0.024,0.04 -0.1432,0.4506 -0.3726,0.9133 l -0.4172,0.8411 -1.3509,0.065 c -0.7429,0.036 -1.9084,0.065 -2.59,0.065 -0.8908,0 -1.3185,0.041 -1.5215,0.146 -0.1553,0.08 -0.301,0.1274 -0.3238,0.1046 -0.06,-0.06 -2.148,0.2224 -3.4339,0.4642 -0.605,0.1137 -1.3386,0.2434 -1.6302,0.2881 -0.2916,0.045 -0.5841,0.1236 -0.65,0.1754 -0.2004,0.1575 -1.1735,0.2315 -1.2179,0.093 z m -0.5868,-4.1877 c -0.075,-0.2801 -0.086,-2.1113 -0.014,-2.2999 0.037,-0.096 0.2169,-0.1238 0.6395,-0.1 1.0183,0.058 5.4962,-0.5228 11.15,-1.4454 2.2777,-0.3717 2.8311,-0.4335 3.0119,-0.3367 0.3001,0.1605 2.0017,1.878 1.9309,1.9488 -0.1459,0.1459 -1.8236,0.7899 -2.5832,0.9916 -1.0267,0.2726 -1.9781,0.4063 -4.35,0.6115 -0.99,0.086 -1.9738,0.2018 -2.1863,0.2581 -0.2124,0.056 -0.5499,0.078 -0.75,0.048 -0.2,-0.03 -1.0162,0.012 -1.8137,0.092 -1.4414,0.1458 -2.5114,0.2256 -3.85,0.287 -0.385,0.018 -0.7951,0.065 -0.9112,0.1048 -0.168,0.058 -0.224,0.025 -0.2737,-0.1603 z"/>
    </g>
    <!-- flowers -->
    <g id="flower">
      <!-- background rectangle -->
      <rect id="rect3531" height="67" width="43" y="1" x="1" fill="#F8F6D8"/>
      <path id="path3533" d="m11.27 58.16l-0.71-8.35c1.76-0.67 2.92-1.76 2.83-2.86s-1.42-1.91-3.26-2.16l-0.71-8.36c1.76-0.67 2.92-1.76 2.83-2.86-0.13-1.56-2.69-2.54-5.71-2.19s-5.37 1.89-5.23 3.44c0.09 1.1 1.42 1.91 3.25 2.16l0.71 8.36c-1.76 0.67-2.92 1.76-2.83 2.86s1.42 1.91 3.25 2.16l0.71 8.36c-1.76 0.67-2.92 1.76-2.83 2.86 0.13 1.55 2.69 2.53 5.71 2.19 3.02-0.35 5.37-1.89 5.23-3.44-0.08-1.11-1.4-1.92-3.24-2.17zm-6.93-23.69c-0.05-0.58 1-1.18 2.34-1.34 1.34-0.15 2.47 0.2 2.52 0.78 0.04 0.49-0.7 0.99-1.74 1.23l0.61 7.13c0.05 0.56-0.19 1.04-0.52 1.08-0.34 0.04-0.65-0.38-0.7-0.94l-0.61-7.13c-1.05 0-1.86-0.32-1.9-0.81zm0.23 13.48c-0.05-0.58 1.41-1.23 3.25-1.44 1.85-0.21 3.39 0.09 3.43 0.67 0.05 0.58-1.41 1.23-3.25 1.44-1.85 0.22-3.38-0.08-3.43-0.67zm4.58 14.05c-1.34 0.15-2.47-0.19-2.52-0.78-0.04-0.49 0.7-0.99 1.74-1.23l-0.61-7.13c-0.05-0.56 0.19-1.04 0.52-1.08s0.65 0.38 0.69 0.94l0.61 7.13c1.06 0 1.87 0.32 1.91 0.81 0.05 0.59-1 1.19-2.34 1.34z" fill="#D3BB54"/>
      <path id="path3535" stroke="#7C5A2D" stroke-width=".25" d="m11.27 58.16l-0.71-8.35c1.76-0.67 2.92-1.76 2.83-2.86s-1.42-1.91-3.26-2.16l-0.71-8.36c1.76-0.67 2.92-1.76 2.83-2.86-0.13-1.56-2.69-2.54-5.71-2.19s-5.37 1.89-5.23 3.44c0.09 1.1 1.42 1.91 3.25 2.16l0.71 8.36c-1.76 0.67-2.92 1.76-2.83 2.86s1.42 1.91 3.25 2.16l0.71 8.36c-1.76 0.67-2.92 1.76-2.83 2.86 0.13 1.55 2.69 2.53 5.71 2.19 3.02-0.35 5.37-1.89 5.23-3.44-0.08-1.11-1.4-1.92-3.24-2.17zm-6.93-23.69c-0.05-0.58 1-1.18 2.34-1.34 1.34-0.15 2.47 0.2 2.52 0.78 0.04 0.49-0.7 0.99-1.74 1.23l0.61 7.13c0.05 0.56-0.19 1.04-0.52 1.08-0.34 0.04-0.65-0.38-0.7-0.94l-0.61-7.13c-1.05 0-1.86-0.32-1.9-0.81zm0.23 13.48c-0.05-0.58 1.41-1.23 3.25-1.44 1.85-0.21 3.39 0.09 3.43 0.67 0.05 0.58-1.41 1.23-3.25 1.44-1.85 0.22-3.38-0.08-3.43-0.67zm4.58 14.05c-1.34 0.15-2.47-0.19-2.52-0.78-0.04-0.49 0.7-0.99 1.74-1.23l-0.61-7.13c-0.05-0.56 0.19-1.04 0.52-1.08s0.65 0.38 0.69 0.94l0.61 7.13c1.06 0 1.87 0.32 1.91 0.81 0.05 0.59-1 1.19-2.34 1.34z" fill="none"/>
      <path id="path3537" stroke="#7C5A2D" stroke-width=".25" d="m5.23 67.99c2.49-8.18-3.33-18.78-3.33-18.78s10.4 10.59 7.48 18.78h-4.15z" fill="#EADDA7"/>
      <path id="path3539" d="m19.02 36.17c-2.92-0.98-5.59-0.56-5.97 0.94-0.27 1.06 0.7 2.38 2.33 3.41l-2.03 8.06c-1.85-0.14-3.28 0.37-3.54 1.43-0.27 1.06 0.7 2.38 2.33 3.41l-2.03 8.06c-1.84-0.14-3.27 0.37-3.54 1.43-0.38 1.5 1.68 3.51 4.6 4.5 2.92 0.98 5.59 0.56 5.96-0.94 0.27-1.06-0.7-2.38-2.32-3.41l2.03-8.06c1.85 0.14 3.28-0.37 3.55-1.43s-0.71-2.38-2.33-3.41l2.03-8.06c1.84 0.14 3.28-0.37 3.54-1.43 0.36-1.51-1.69-3.52-4.61-4.5zm-4.61 20.87l-1.73 6.88c0.98 0.45 1.63 1.1 1.51 1.58-0.14 0.56-1.31 0.66-2.6 0.23-1.3-0.44-2.23-1.25-2.09-1.81 0.12-0.47 0.97-0.62 2.01-0.39l1.73-6.88c0.13-0.54 0.51-0.88 0.83-0.77 0.32 0.1 0.47 0.62 0.34 1.16zm3.91-4.16c-0.14 0.56-1.7 0.53-3.48-0.07s-3.11-1.54-2.97-2.11c0.14-0.56 1.7-0.53 3.48 0.07s3.11 1.55 2.97 2.11zm2.36-13.21c-0.12 0.47-0.97 0.62-2.01 0.39l-1.73 6.88c-0.13 0.54-0.51 0.88-0.83 0.77s-0.48-0.63-0.34-1.17l1.73-6.88c-0.98-0.45-1.63-1.1-1.51-1.58 0.14-0.56 1.31-0.67 2.6-0.23 1.3 0.45 2.23 1.26 2.09 1.82z" fill="#DBC879"/>
      <path id="path3541" stroke="#7C5A2D" stroke-width=".25" d="m19.02 36.17c-2.92-0.98-5.59-0.56-5.97 0.94-0.27 1.06 0.7 2.38 2.33 3.41l-2.03 8.06c-1.85-0.14-3.28 0.37-3.54 1.43-0.27 1.06 0.7 2.38 2.33 3.41l-2.03 8.06c-1.84-0.14-3.27 0.37-3.54 1.43-0.38 1.5 1.68 3.51 4.6 4.5 2.92 0.98 5.59 0.56 5.96-0.94 0.27-1.06-0.7-2.38-2.32-3.41l2.03-8.06c1.85 0.14 3.28-0.37 3.55-1.43s-0.71-2.38-2.33-3.41l2.03-8.06c1.84 0.14 3.28-0.37 3.54-1.43 0.36-1.51-1.69-3.52-4.61-4.5zm-4.61 20.87l-1.73 6.88c0.98 0.45 1.63 1.1 1.51 1.58-0.14 0.56-1.31 0.66-2.6 0.23-1.3-0.44-2.23-1.25-2.09-1.81 0.12-0.47 0.97-0.62 2.01-0.39l1.73-6.88c0.13-0.54 0.51-0.88 0.83-0.77 0.32 0.1 0.47 0.62 0.34 1.16zm3.91-4.16c-0.14 0.56-1.7 0.53-3.48-0.07s-3.11-1.54-2.97-2.11c0.14-0.56 1.7-0.53 3.48 0.07s3.11 1.55 2.97 2.11zm2.36-13.21c-0.12 0.47-0.97 0.62-2.01 0.39l-1.73 6.88c-0.13 0.54-0.51 0.88-0.83 0.77s-0.48-0.63-0.34-1.17l1.73-6.88c-0.98-0.45-1.63-1.1-1.51-1.58 0.14-0.56 1.31-0.67 2.6-0.23 1.3 0.45 2.23 1.26 2.09 1.82z" fill="none"/>
      <path id="path3543" stroke="#7C5A2D" stroke-width=".25" d="m19.85 67.7c-1.77-5.79 2.35-13.28 2.35-13.28s-7.35 7.49-5.29 13.28h2.94z" fill="#EADA9B"/>
      <path id="path3545" stroke="#7C5A2D" d="m30.33 52.2c-10.89 0-12.13-1.84-15.85-5.97 4.7-3.44 10.9-3.9 16.34 4.82l-0.49 1.15z" fill="#BFAA52"/>
      <path id="path3547" d="m27.52 50.68c-6.89 0-7.68-1.16-10.03-3.78 2.98-2.18 6.9-2.47 10.34 3.05l-0.31 0.73z" fill="#DBC775"/>
      <path id="path3549" stroke="#7C5A2D" d="m42.27 47.51c-0.36 2.52-6.85 4.67-9.62 5.14s1.52-5.63 6.18-9.5c2.95-0.51 3.67 2.79 3.44 4.36z" fill="#BFAA52"/>
      <path id="path3551" d="m37.59 49.31c-0.15 1.08-2.95 2.01-4.14 2.21s0.66-2.42 2.66-4.09c1.27-0.22 1.58 1.2 1.48 1.88z" fill="#DBC775"/>
      <path id="path3553" stroke="#7C5A2D" stroke-width=".75" d="m38.25 67.92c-7.82-3.7-5.44-11.92-5.44-18.72l-2.23-0.29s-2.8 17.48 4.83 18.76l2.84 0.25z" fill="#E5D389"/>
      <path id="path3555" stroke="#7C5A2D" d="m43.33 52.91v7.75s-2.47 2.07-4.21 2.07c-1.73 0-6.93-9.55-6.44-10.59 0.51-1.04 10.16-1.29 10.65 0.77z" fill="#BFAA52"/>
      <path id="path3557" d="m40.06 53.5c1.02 0.72 0 3.43 0 3.43s-1.33 0.91-2.27 0.91c-0.93 0-3.73-4.22-3.47-4.68s4.72-0.37 5.74 0.34z" fill="#DBC775"/>
      <path id="path3559" stroke="#7C5A2D" d="m31.45 52.39c-12.87-1.29-10.89 4.39-14.11 10.07 10.15 2.84 10.89-5.42 14.11-10.07z" fill="#BFAA52"/>
      <path id="path3561" d="m30.26 53.1c-8.21-0.82-6.95 2.8-9 6.42 6.48 1.82 6.95-3.45 9-6.42z" fill="#E2CF7F"/>
      <path id="path3563" stroke="#7C5A2D" d="m32.93 50.42s3.69-9.06-0.25-11.11c-4.04-2.11-6.64-1.29-7.13 0-0.5 1.29 3.91 12.41 5.65 12.66 1.73 0.26 1.73-1.55 1.73-1.55z" fill="#BFAA52"/>
      <path id="path3565" d="m32.14 50.27s2.05-5.67-0.14-6.95c-2.24-1.32-3.68-0.81-3.96 0s2.17 7.76 3.13 7.92c0.97 0.16 0.97-0.97 0.97-0.97z" fill="#DBC775"/>
      <path id="path3567" stroke="#7C5A2D" stroke-width=".25" d="m31.45 51.12s-1.48-2.54-1.23-4.87" fill="#EADDA7"/>
      <path id="path3569" stroke="#7C5A2D" d="m30.33 52.6s-4.13 5.57-2.01 5.48c2.41-0.11 2.6 0 5.1 0.46 2.57 0.47 0.2-5.55-1.6-6.32l-1.49 0.38z" fill="#BFAA52"/>
      <path id="path3571" stroke="#7C5A2D" stroke-width=".5" d="m27.27 48.13s2.02 2.93 3.35 2.93 0.61 2.18 0 1.56c-0.62-0.63-2.47-2.43-3.57-2.62-0.82 0-1.01-2.34 0.22-1.87z" fill="#DBC879"/>
      <path id="path3573" stroke="#AF9A41" d="m44 12.51c-4.46 0-8.54 2.85-8.54 6.37s4.08 6.37 8.54 6.37v-12.74z" fill="#D3BB54"/>
      <path id="path3575" stroke="#AF9A41" d="m33.33 7.64c0-3.52-3.62-6.23-8.08-6.23s-8.08 2.71-8.08 6.23 3.62 6.37 8.08 6.37c4.46 0 8.08-2.85 8.08-6.37z" fill="#D3BB54"/>
      <ellipse id="ellipse3577" cy="17.54" rx="8.08" ry="6.37" stroke="#AF9A41" cx="29.56" fill="#D3BB54"/>
      <path id="path3579" stroke="#AF9A41" d="m44 16.35v-14.93h-13.1c-2.93 1.56-3.79 4.49-3.79 7.49 0 4.79 4.93 8.68 11.02 8.68 2.08-0.01 4.21-0.46 5.87-1.24z" fill="#DBC879"/>
      <path id="path3581" stroke="#AF9A41" d="m31.94 15.47s-0.72 1.82-3.03 1.82" fill="#D3BB54"/>
      <path id="path3583" stroke="#AF9A41" d="m27.19 6.62s-1.73 0.57-3.17-1.02" fill="#D3BB54"/>
      <path id="path3587" d="m31.13 52.9s-1.71 2.31-0.83 2.27c1-0.04 1.08 0 2.11 0.19 1.06 0.2 0.08-2.3-0.66-2.62l-0.62 0.16z" fill="#E2CF7F"/>
      <rect id="rect3585" stroke="#633" stroke-width="2" height="65" width="41" y="2" x="2" fill="none"/>
    </g>
    <!-- seasons -->
    <g id="season">
      <!-- background rectangle and frame -->
      <rect id="rect3590" height="67" width="43" y="1" x="1" fill="#E3E4FF" stroke="#678ED3" stroke-width="1"/>
      <!-- snowflake -->
      <polygon id="polygon3592" stroke="#99B9FF" points="4.69 42.38 9.02 39.76 10.2 44.33 6.26 48.26 8.62 49.89 10.2 48.26 10.98 51.52 14.91 51.19 14.52 47.93 17.27 49.24 18.85 47.28 14.13 44.01 13.34 39.44 19.24 41.4 20.81 45.97 23.56 44.99 22.77 42.7 26.71 44.33 28.28 41.07 23.96 39.44 27.11 38.45 25.92 36.17 20.42 37.8 14.91 35.84 20.03 32.9 25.92 33.88 26.31 31.27 23.17 30.94 26.31 28.98 23.96 26.37 20.81 28 20.81 26.04 18.06 25.71 17.27 30.61 12.55 33.23 11.77 28.66 15.7 24.41 12.95 23.1 11.38 25.06 10.58 21.47 7.05 22.12 7.45 25.39 4.69 24.08 3.12 25.71 7.45 28.66 8.23 33.55 3.12 31.92 1 27.81 1 34.92 1.16 34.86 6.26 36.82 1.55 39.76 1 39.66 1 45.06 1.16 44.99 1 45.91 1 47.31 3.51 47.6" fill="#CAE0FF"/>
      <!-- sun core circle -->
      <path id="path3594" stroke="#678ED3" d="m40.63 26.67c1.1 0 2.17-0.13 3.21-0.35v-24.82h-14.3c-2.44 2.67-3.95 6.22-3.95 10.13 0 8.31 6.73 15.04 15.04 15.04z" fill="#99B9FF"/>
      <!-- small triangles -->
      <polygon id="polygon3596" fill="#C9D3F2" stroke="#9EB3E8" stroke-width=".5" points="22.61 14.9 22.3 14.59 20.96 16.9 23.27 18.23 23.39 17.81"/>
      <polygon id="polygon3598" fill="#C9D3F2" stroke="#9EB3E8" stroke-width=".5" points="34.45 28.87 34.03 28.98 35.36 31.29 37.67 29.96 37.35 29.65"/>
      <polygon id="polygon3602" fill="#C9D3F2" stroke="#9EB3E8" stroke-width=".5" points="23.39 5.45 23.27 5.03 20.96 6.36 22.3 8.67 22.61 8.36"/>
      <polygon id="polygon3606" fill="#C9D3F2" stroke="#9EB3E8" stroke-width=".5" points="26.66 23.47 26.23 23.36 26.23 26.02 28.9 26.02 28.78 25.6"/>
      <polygon id="polygon3600" fill="#798CD8" points="43.83 30.1 43.83 29.71 43.59 29.96"/>
      <!-- large triangles -->
      <polygon id="polygon3604" fill="#99B9FF" stroke="#678ED3" points="23.31 15.6 23.31 7.66 22.61 8.36 22.3 8.67 19.34 11.63 22.3 14.59 22.61 14.9"/>
      <polygon id="polygon3608" fill="#99B9FF" stroke="#678ED3" points="37.35 29.65 37.67 29.96 40.63 32.92 43.59 29.96 43.83 29.71 43.83 28.95 36.66 28.95"/>
      <polygon id="polygon3610" fill="#99B9FF" stroke="#678ED3" points="35.41 28.61 28.53 24.64 28.78 25.6 28.9 26.02 29.98 30.07 34.03 28.98 34.45 28.87"/>
      <polygon id="polygon3612" fill="#99B9FF" stroke="#678ED3" points="27.61 23.73 23.64 16.85 23.39 17.81 23.27 18.23 22.19 22.27 26.23 23.36 26.66 23.47"/>
      <polygon id="polygon3614" fill="#99B9FF" stroke="#678ED3" points="23.39 5.45 23.64 6.41 26.48 1.5 22.33 1.5 23.27 5.03"/>
      <!-- cloud -->
      <path id="path3616" fill="#99B9FF" stroke="#678ED3" d="m30.67 46.67s2.32-3 7-3c5.67 0 5.67 9.33 5.67 9.33h-23.67s-0.33-6.67 7.67-6.67c3.67 0 6 4 6 4"/>
      <!-- raindrops -->
      <path id="path3618" stroke="#678ED3" fill="#99B9FF"
	    d="M29.5,57.27L24.83,65.36 M34.22,55.68L28.68,65.95 M23.33,61L20.5,65.91 M37.46,54.63L33.25,62.59 M40.46,62.17L38.13,66.21
	       M27.11,54.52L24.44,59.14 M31.67,54L30.67,55.73 M40.98,55.6L37.81,61.09 M23.84,55.04L22.18,57.92 M21.13,55.63L16.91,63.59
	       M36,63.6L35,65.33"/>
      <!-- frame -->
      <rect id="rect3640" fill="none" stroke="#678ED3" stroke-width="1" height="65" width="41" y="2" x="2"/>
    </g>
    <!-- coins -->
    <g id="one-coin">
      <path id="path4320" stroke="#10106C" stroke-width=".75" d="m49.4 40.5c0 7.7-6.2 13.9-13.9 13.9s-13.9-6.2-13.9-13.9 6.2-13.9 13.9-13.9 13.9 6.2 13.9 13.9z" fill="none"/>
      <circle id="circle4322" r="6.5" cy="40.5" stroke="#10106C" cx="42" stroke-width="1.6" fill="none"/>
      <circle id="circle4324" r="6.5" cy="40.5" stroke="#10106C" cx="29" stroke-width="1.6" fill="none"/>
      <circle id="circle4326" r="6.5" cy="34" stroke="#10106C" cx="35.5" stroke-width="1.6" fill="none"/>
      <circle id="circle4328" r="6.5" cy="47" stroke="#10106C" cx="35.5" stroke-width="1.6" fill="none"/>
      <path id="path4330" stroke="#10106C" stroke-width=".75" d="m44.8 40.5c0 5.1-4.2 9.3-9.3 9.3s-9.3-4.2-9.3-9.3c0-5.1 4.2-9.3 9.3-9.3s9.3 4.2 9.3 9.3z" fill="none"/>
      <path id="path4332" stroke="#BA0000" stroke-width="2" d="m52.2 40.5c0 9.2-7.5 16.7-16.7 16.7s-16.7-7.5-16.7-16.7 7.5-16.7 16.7-16.7 16.7 7.5 16.7 16.7z" fill="none"/>
      <path id="path4334" stroke="#10106C" stroke-width=".75" d="m55 40.5c0 10.8-8.7 19.5-19.5 19.5s-19.5-8.7-19.5-19.5 8.7-19.5 19.5-19.5 19.5 8.7 19.5 19.5z" fill="none"/>
    </g>
    <g id="two-coins">
      <use id="use3882" xlink:href="#coin" stroke="#10106C" transform="translate(24.5 16.5) scale(1.22)"/>
      <use id="use3884" xlink:href="#coin" stroke="#10106C" transform="translate(24.5 42.5) scale(1.22)"/>
    </g>
    <g id="three-coins">
      <use id="use3890" xlink:href="#coin" stroke="#10106C"  transform="translate(16.5 12.5)"/>
      <use id="use3894" xlink:href="#coin" stroke="#9C0000" transform="translate(26.5 31.5)"/>
      <use id="use3898" xlink:href="#coin" stroke="#10106C"  transform="translate(36.5 50.5)"/>
    </g>
    <g id="four-coins">
      <use id="use3902" xlink:href="#coin" stroke="#10106C" transform="translate(17 15) scale(.94)"/>
      <use id="use3904" xlink:href="#coin" stroke="#10106C" transform="translate(17 49) scale(.94)"/>
      <use id="use3910" xlink:href="#coin" stroke="#10106C" transform="translate(37 15) scale(.94)"/>
      <use id="use3912" xlink:href="#coin" stroke="#10106C" transform="translate(37 49) scale(.94)"/>
    </g>
    <g id="five-coins">
      <use id="use3918" xlink:href="#coin" stroke="#10106C"  transform="translate(17.5 13.5) scale(.88)"/>
      <use id="use3920" xlink:href="#coin" stroke="#10106C"  transform="translate(17.5 51.5) scale(.88)"/>
      <use id="use3926" xlink:href="#coin" stroke="#9C0000" transform="translate(27.5 32.5) scale(.88)"/>
      <use id="use3930" xlink:href="#coin" stroke="#10106C"  transform="translate(37.5 13.5) scale(.88)"/>
      <use id="use3932" xlink:href="#coin" stroke="#10106C"  transform="translate(37.5 51.5) scale(.88)"/>
    </g>
    <g id="six-coins">
      <use id="use3938" xlink:href="#coin" stroke="#10106C" transform="translate(20 14) scale(.72)"/>
      <use id="use3940" xlink:href="#coin" stroke="#9C0000" transform="translate(20 37) scale(.72)"/>
      <use id="use3942" xlink:href="#coin" stroke="#9C0000" transform="translate(20 54) scale(.72)"/>
      <use id="use3950" xlink:href="#coin" stroke="#10106C" transform="translate(38 14) scale(.72)"/>
      <use id="use3952" xlink:href="#coin" stroke="#9C0000" transform="translate(38 37) scale(.72)"/>
      <use id="use3954" xlink:href="#coin" stroke="#9C0000" transform="translate(38 54) scale(.72)"/>
    </g>
    <g id="seven-coins">
      <use id="use3962" xlink:href="#coin" stroke="#10106C" transform="translate(15 10) scale(.72)"/>
      <use id="use3964" xlink:href="#coin" stroke="#9C0000" transform="translate(20 41) scale(.72)"/>
      <use id="use3966" xlink:href="#coin" stroke="#9C0000" transform="translate(20 58) scale(.72)"/>
      <use id="use3968" xlink:href="#coin" stroke="#10106C" transform="translate(29 17) scale(.72)"/>
      <use id="use3970" xlink:href="#coin" stroke="#10106C" transform="translate(43 24) scale(.72)"/>
      <use id="use3978" xlink:href="#coin" stroke="#9C0000" transform="translate(38 41) scale(.72)"/>
      <use id="use3980" xlink:href="#coin" stroke="#9C0000" transform="translate(38 58) scale(.72)"/>
    </g>
    <g id="eight-coins">
      <use id="use3990" xlink:href="#coin" stroke="#10106C" transform="translate(21 10) scale(.72)"/>
      <use id="use3992" xlink:href="#coin" stroke="#10106C" transform="translate(21 26) scale(.72)"/>
      <use id="use3994" xlink:href="#coin" stroke="#10106C" transform="translate(21 42) scale(.72)"/>
      <use id="use3996" xlink:href="#coin" stroke="#10106C" transform="translate(21 58) scale(.72)"/>
      <use id="use4006" xlink:href="#coin" stroke="#10106C" transform="translate(37 10) scale(.72)"/>
      <use id="use4008" xlink:href="#coin" stroke="#10106C" transform="translate(37 26) scale(.72)"/>
      <use id="use4010" xlink:href="#coin" stroke="#10106C" transform="translate(37 42) scale(.72)"/>
      <use id="use4012" xlink:href="#coin" stroke="#10106C" transform="translate(37 58) scale(.72)"/>
    </g>
    <g id="nine-coins">
      <use id="use4022" xlink:href="#coin" stroke="#10106C" transform="translate(14 14) scale(.72)"/>
      <use id="use4024" xlink:href="#coin" stroke="#9C0000" transform="translate(14 34) scale(.72)"/>
      <use id="use4026" xlink:href="#coin" stroke="#10106C" transform="translate(14 54) scale(.72)"/>
      <use id="use4034" xlink:href="#coin" stroke="#10106C" transform="translate(29 14) scale(.72)"/>
      <use id="use4036" xlink:href="#coin" stroke="#9C0000" transform="translate(29 34) scale(.72)"/>
      <use id="use4038" xlink:href="#coin" stroke="#10106C" transform="translate(29 54) scale(.72)"/>
      <use id="use4046" xlink:href="#coin" stroke="#10106C" transform="translate(44 14) scale(.72)"/>
      <use id="use4048" xlink:href="#coin" stroke="#9C0000" transform="translate(44 34) scale(.72)"/>
      <use id="use4050" xlink:href="#coin" stroke="#10106C" transform="translate(44 54) scale(.72)"/>
    </g>
    <!-- winds -->
    <path id="north-wind" d="m56.3 54.7c-2-0.9-11.8 3.3-11.8 3.3l0.5-20.7s5.3-4.3 9.6-1.7l-1.2-5c-1.4-0.2-8.4 5.5-8.4 5.5s-0.6-18.8 4.8-19.9-8.9-2.6-9.7-2.2c-0.4 0.2-0.4 13.8-0.2 27.1-3.2 3.1-5.9 6.2-7.1 7.3l0.4-28.5s-4.7-2.6-5.8-1.4l0.2 14.8c-0.3-0.5-0.7-0.9-1-1.3-1-1.3-6.1-4.2-6.1-4.2s1.7 5.6 2.5 6.6c0.7 0.9 3 2.9 4.6 2.2l0.2 16.5c-3.4 3-7.9 6.8-8.5 5.4-1.5-3.2-4.7-3-5.2-1.5-0.5 1.6 4.2 10.2 5.8 10.1 0.8-0.1 4.4-4.9 8-10l0.1 5.3c1.6 2.1 3.8 0.5 4.6-0.7l0.3-11c1.1-1.6 4-4.5 7.1-7.9 0.2 12.1 0.3 22.8 0.3 22.8 4.9-5.2 16.7-4 16.7-4l-0.7-6.9z" fill="#101040"/>
    <g id="west-wind">
      <path id="path4304" d="m48.4 14.3c-8.5 5.7-21.5 6.9-28.8 5.9l-0.9 2c11.7 3.8 26.4 1 31.2-3.2l-1.5-4.7z" fill="#101040"/>
      <path id="path4306" d="m52.5 39.2c-3.6-0.9-7.3-1.4-10.8-1.7 0.8-2.9 1.2-6 1-9.2l-7.8 2c0.6 1.7 0.6 4.3 0.2 7-1.6 0-3.1 0.1-4.5 0.3 0.2-2.7 0.4-3.3-0.5-6l-4.7 1.3c1 1.8 1.5 2.3 1.8 5.1-3.4 1-5.7 1.8-6.9 3.2-5.1 6.1 0 23.2 0 23.2s-0.2-15.4 2-17c2.2-1.6 4.7-1.8 4.7-1.8 0.1 1.5-1.6 6.7-1.6 6.7 2.2-2.7 3.2-3.6 4.3-7.2 1.6-0.5 2.5-0.8 4.1-1-1.6 6.1-4.5 10.9-4.5 10.9l7.4 2c-4.1-0.1-13.3 5.1-13.3 5.1s16.2-4 20.8-1.1l1.2-2.9c-3.4-2.7-10.5-4.9-10.5-4.9s2.2-4.1 4.6-9.4c2.3 0.1 5.6 0.3 7.7 0.9 9.2 4.1-1.7 22.4-1.7 22.4s20.2-21.2 7-27.9z" fill="#101040"/>
    </g>
    <g id="south-wind" fill="#101040">
      <path id="path3389" d="m 45.6679,67.1678 c -0.1335,-0.2298 -1.3685,-2.3813 -2.7444,-4.781 l -2.5016,-4.3633 0.2501,-0.2501 0.2501,-0.2501 0.8927,0.6318 c 1.7593,1.2452 3.1068,1.8546 4.1333,1.869 0.7196,0.01 1.0726,-0.1514 1.5956,-0.7303 0.9673,-1.0707 1.5314,-3.1307 2.2703,-8.2911 0.2662,-1.8588 0.3009,-2.337 0.254,-3.5027 -0.083,-2.0746 -0.5869,-3.7994 -1.5179,-5.1998 -0.8418,-1.2663 -2.0461,-2.1175 -3.4566,-2.443 -0.4043,-0.093 -1.4613,-0.1706 -2.8435,-0.2079 l -2.2,-0.059 -1.8157,2.3049 -1.8157,2.3049 0.6832,-0.063 0.6831,-0.064 0.1037,0.3886 c 0.057,0.2138 0.2153,0.8071 0.3517,1.3186 l 0.2479,0.9298 -0.2191,-0.07 c -0.2626,-0.084 -2.8029,-0.07 -3.5433,0.02 -0.5013,0.061 -0.5283,0.079 -0.6177,0.4269 -0.1733,0.6745 -0.425,2.03 -0.3844,2.0706 0.022,0.022 0.3971,-0.031 0.8333,-0.119 1.0472,-0.2104 2.8611,-0.2208 3.393,-0.019 l 0.4,0.1514 0.028,1.5268 c 0.022,1.2215 0,1.5168 -0.1026,1.4768 -0.5788,-0.2221 -1.5249,-0.3188 -3.1416,-0.321 -0.999,0 -1.8489,0.03 -1.8885,0.069 -0.04,0.04 -0.2908,1.1646 -0.5581,2.5 -0.2673,1.3355 -0.5344,2.6643 -0.5935,2.9531 -0.1046,0.5104 -0.1171,0.525 -0.4505,0.525 -0.2597,0 -0.343,-0.042 -0.3435,-0.175 0,-0.4185 -0.3088,-5.3678 -0.335,-5.3939 -0.043,-0.043 -1.8938,0.5457 -2.4046,0.7647 l -0.4408,0.1889 -0.7095,-0.7317 c -0.3902,-0.4024 -0.7095,-0.7759 -0.7095,-0.83 0,-0.1225 1.6204,-0.7975 2.95,-1.229 0.55,-0.1785 1.0314,-0.3514 1.0698,-0.3842 0.065,-0.056 -0.1022,-2.8163 -0.1753,-2.8958 -0.05,-0.054 -2.0997,0.3714 -2.8398,0.589 -0.3549,0.1044 -0.6547,0.1801 -0.6662,0.1684 -0.047,-0.049 -0.2501,-2.3931 -0.2104,-2.4328 0.059,-0.059 1.3265,-0.3149 2.4219,-0.4893 1.3664,-0.2176 1.35,-0.2109 1.35,-0.5512 0,-0.1714 0.053,-0.2985 0.125,-0.2989 0.2688,-0 4.304,-0.3954 4.3211,-0.4215 0.052,-0.079 0.6474,-4.2176 0.612,-4.2529 -0.055,-0.055 -6.6348,0.3611 -6.9581,0.4398 -0.2829,0.069 -2.0026,0.2944 -3.35,0.4394 -1.8582,0.2 -5.1106,0.7229 -5.3887,0.8664 -0.6258,0.3228 -1.1478,1.1537 -1.4154,2.2527 -0.2188,0.8987 -0.2946,3.3712 -0.1542,5.0269 0.2903,3.4228 1.3936,8.9407 2.657,13.2883 0.142,0.4885 0.2413,0.9051 0.2207,0.9257 -0.021,0.021 -0.2164,-0.092 -0.4351,-0.2506 -0.8339,-0.6041 -3.5144,-5.1409 -4.9413,-8.3634 -2.6247,-5.9277 -2.981,-10.3119 -1.0475,-12.89 0.9844,-1.3125 2.4647,-2.1656 4.6085,-2.6557 2.7538,-0.6296 6.6156,-1.2389 10.1341,-1.5989 1.066,-0.1091 1.9559,-0.2161 1.9776,-0.2377 0.065,-0.065 0.4612,-7.7741 0.4029,-7.8324 -0.076,-0.076 -2.8338,0.3395 -3.6837,0.5553 l -0.7106,0.1805 -1.3409,-1.3018 c -0.7375,-0.716 -1.3038,-1.3389 -1.2585,-1.3842 0.1617,-0.1617 1.6145,-0.4674 4.1751,-0.8787 1.43,-0.2297 2.7076,-0.44 2.8391,-0.4674 l 0.239,-0.05 -0.06,-3.8195 c -0.061,-3.9008 -0.1931,-5.613 -0.5208,-6.7445 -0.092,-0.3163 -0.2129,-0.6314 -0.2694,-0.7001 -0.071,-0.086 -0.066,-0.1687 0.015,-0.2671 0.099,-0.1198 0.247,-0.067 0.9372,0.3326 0.4506,0.2612 2.1243,1.2305 3.7193,2.1542 1.595,0.9236 3.0436,1.7659 3.219,1.8717 l 0.319,0.1925 -0.1979,0.3354 c -0.347,0.5881 -2.1612,6.0179 -2.0484,6.1307 0.022,0.022 0.6183,-0.01 1.3244,-0.065 0.7062,-0.058 1.9276,-0.1359 2.7144,-0.1729 l 1.4304,-0.067 -0.057,0.4901 c -0.032,0.2696 -0.1265,1.3214 -0.211,2.3374 -0.084,1.0159 -0.1666,1.8601 -0.1825,1.876 -0.016,0.016 -0.2137,-0.036 -0.4395,-0.1159 -0.7209,-0.2544 -2.0207,-0.3884 -3.8602,-0.398 l -1.7895,-0.01 -1.0331,3.894 c -0.5683,2.1417 -1.0167,3.9105 -0.9965,3.9306 0.02,0.02 0.9079,-0.01 1.9727,-0.065 3.121,-0.1645 9.0702,-0.2329 11.286,-0.1297 1.8884,0.088 2.1226,0.1199 2.9711,0.4048 3.5044,1.1766 5.7652,3.6548 6.5299,7.1576 0.3137,1.4368 0.2901,4.0689 -0.055,6.136 -0.2295,1.375 -1.16,5.2571 -1.7527,7.3129 -1.4176,4.917 -2.6555,6.8576 -5.3078,8.3207 -0.8027,0.4428 -2.3633,1.1179 -3.4552,1.4947 l -0.5197,0.1794 -0.2427,-0.4178 z m -10.6996,-23.1866 c -0.032,-0.08 -0.056,-0.056 -0.06,0.06 -0,0.1054 0.019,0.1644 0.053,0.1312 0.033,-0.033 0.037,-0.1195 0.01,-0.1917 z"/>
      <path id="path3368" d="m 29.0619,47.2 c -0.2531,-1.0047 -0.8964,-2.0327 -2.77,-4.426 -1.3006,-1.6614 -1.9314,-2.5496 -2.0051,-2.8231 -0.1341,-0.498 -0.3885,-0.8653 -1.0325,-1.4904 l -0.5043,-0.4895 0.3936,-0.088 c 0.5494,-0.1226 4.3558,-0.6655 5.2199,-0.7445 l 0.7135,-0.065 0.068,2.1383 c 0.091,2.8706 0.033,8.4499 -0.083,7.9883 z"/>
    </g> 
    <path id="east-wind" d="m36.5 41.3l0.1-6.4 4.4-0.3-0.3-2.4-4.1 1.2v-5.7c2.4 0.3 5 0.8 7.1 0.9 4.3 0.3-1.2 14.1-1.2 14.1s16.3-14.4 2.6-18.1c-1.4 0-4.9 0.2-8.4 0.4v-3.9l7.5-1.9-7.5-0.1v-4l-4.6-3.4 0.5 8.7-4 2.7 4.1-1 0.2 3.2c-1.8 0.2-3.4 0.3-4.3 0.5-11.5 2.2 1 17.2 1 17.2s-4-14 0.5-15.3c0.9-0.3 1.8-0.3 2.9-0.3l0.4 7-3 0.9 3-0.2 0.2 4.1c-9.2 12.1-19.7 16.6-19.7 16.6s10.2-1.1 20-11.9l1 18.7c-3.7-1.5-7-3.6-7-3.6s2.4 7.1 7.5 10.1l4.3-5.1c-1-0.2-2.1-0.5-3.2-0.9l0.2-18.9c2.7 3.2 9 10.5 11.7 11l9-3c-3.5-0.6-17.7-8.9-20.9-10.9z" fill="#101040"/>
    <!-- dragons -->
    <g id="red-dragon" fill="#BA0000" >
      <path id="path3350" d="m 33.7,70.3608 c -0.9009,-11.0199 -1.6813,-22.0526 -2.702,-33.0608 -0.4004,-3.5458 -0.3299,-7.1389 -0.6169,-10.7 -1.4562,0.2567 -4.6276,-0.6188 -3.5933,1.8115 0.1924,2.9201 0.6382,5.805 1.1357,8.6819 0.086,0.9752 0.5429,3.569 -0.9155,1.9898 -3.116,-2.627 -3.2078,-7.0399 -3.8063,-10.7594 -0.011,-1.8677 -2.2395,-4.5297 1.0818,-4.4984 1.8309,-0.5692 5.1865,0.2923 5.9975,-1.2212 -0.2304,-3.2354 -0.1711,-6.5049 -0.8689,-9.6866 -1.0612,-2.8977 2.1596,-3.97258 4.1399,-2.3879 1.5812,0.8934 5.8509,2.0388 3.8848,4.4922 -1.6257,1.6632 -1.0497,4.075 -1.2134,6.1776 -0.019,0.8199 -0.3187,1.932 0.891,1.4719 2.5675,-0.083 5.1446,-0.3215 7.7101,-0.1959 2.5275,0.4421 4.6745,2.9248 3.9533,5.5586 -1.2578,4.8929 -5.0769,8.5806 -8.6289,11.9496 -1.1626,0.9645 0.4714,-2.1184 0.4094,-2.8196 0.7416,-3.0475 1.6404,-6.1133 1.8588,-9.285 0.3663,-2.1652 -3.2549,-0.5885 -4.5926,-1.2191 -1.8487,-0.8228 -1.8681,0.441 -1.7966,1.8416 -0.3728,14.0016 -0.9076,27.9987 -1.3273,41.9986 -0.3124,-0.056 -0.7738,0.1372 -1.0006,-0.1394 z" />
      <path id="path3348" d="m 39.1,37.3873 c -2.6463,-0.1431 -5.306,0.016 -7.9456,-0.2414 -1.9723,-0.2403 -3.9522,-0.4091 -5.9318,-0.5764 -0.5693,-0.3617 -0.6089,-1.2127 -0.871,-1.8011 -0.1725,-0.3512 0,-0.4284 0.3393,-0.3681 1.9127,-0.032 3.8236,0.08 5.7252,0.2827 4.3112,0.2777 8.6348,0.3933 12.9545,0.3321 0.4295,0.053 1.312,-0.1778 1.4377,0.1312 -0.588,0.7905 -1.2745,1.5004 -1.9198,2.2433 -1.2626,0.029 -2.528,0.065 -3.7885,-0 z"/>
      <!--path id="path3338" d="m 34,70 c -1,-5 -1,-10 -1,-14 -1,-7 -2,-14 -2,-20 0,-3 0,-5 -1,-7 0,-1 0,-2 -1,-2 -1,0 -2,0 -2,1 0,2 0,4 0,7 1,0 1,1 1,2 0,1 0,2 0,3 -2,-1 -3,-3 -4,-5 0,-3 -1,-5 -1,-7 0,-2 -2,-3 1,-4 2,0 4,-1 6,-1 0,0 0,-2 0,-2 0,-2 0,-4 0,-6 -1,-2 -1,-5 1,-5.3 2,0.1 5,1.3 7,3.3 0,1 -2,3 -2,5 0,1 0,3 0,5 2,0 4,0 5,0 2,-1 4,-1 5,0 1,0 3,1 3,3 0,2 0,3 -1,5 -2,3 -4,6 -6,8 -2,2 -2,-1 -1,-2 0,-1 -1,-2 1,-3 0,0 0,-2 0,-2 0,-2 0,-4 1,-5 -2,0 -5,0 -7,0 0,6 0,12 0,19 -1,6 -1,12 -1,18 0,2 0,4 0,7 -1,1 -1,0 -1,-1 z" /-->
      <!--path id="path3340" d="m 35,37 c -3,0 -7,0 -10,0 0,-1 0,-1 -1,-2 0,0 0,0 0,-1 0,0 0,0 0,0 1,0 2,0 3,0 1,0 1,1 2,1 5,0 11,0 16,0 -1,1 -1,1 -2,2 -3,0 -5,0 -8,0 z" /-->
    </g>
    <g id="green-dragon" fill="#004C00">
      <path id="path3352" d="m 42.7387,63.325 c -0.998,-2.7004 -2.8125,-4.991 -4.4475,-7.3283 -2.1887,1.8509 -4.4161,4.0535 -7.3437,4.5541 -1.5697,0.062 -2.2376,-1.3014 -0.4242,-1.7503 2.2029,-1.4421 4.2785,-3.0832 6.175,-4.9103 -1.8003,-2.2983 -3.5866,-4.6077 -5.4069,-6.8902 5.2183,-0.062 10.4764,-0.3735 15.6677,-0.3329 -0.8568,0.9164 -1.4954,2.8208 -2.974,2.6889 -2.1911,0.097 -4.4106,0.033 -6.5675,0.4546 2.5959,3.2538 6.0035,6.068 7.8078,9.9325 0.6742,1.117 0.1687,2.0053 -0.8383,2.5538 -0.4738,0.229 -1.2568,1.3545 -1.6484,1.0281 z m -18.569,-1.1049 c -1.4094,-3.6263 -2.8091,-7.2565 -4.1891,-10.8941 0.7543,-1.3046 1.3062,0.133 1.828,0.7741 0.9944,1.1489 1.9723,4.0059 3.5472,1.761 2.2231,-1.9639 3.2993,-4.8051 4.1505,-7.5611 1.2935,3.199 1.556,7.203 -0.8375,9.9742 -1.4305,1.8228 -3.3629,3.543 -3.4328,6.0378 -0.2826,0.2157 -0.9894,0.4783 -1.0663,-0.092 z m -1.6336,-11.7301 c -0.6093,-0.9137 1.1707,-2.1084 1.3384,-3.1993 0.6081,-1.1949 1.5724,-2.4905 -0.4309,-2.2031 -1.0194,-0.5484 -4.0475,-2.9571 -1.1348,-2.3068 1.9386,0.2507 4.0913,0.5163 4.1609,-2.0319 1.3162,-2.0364 -1.7527,-0.075 -1.6915,-1.6543 0.2512,-0.6764 1.5788,-0.9426 2.2135,-1.473 1.4749,-0.6089 3.9618,-2.6994 4.8237,-2.4546 -0.9622,2.6873 -2.2579,5.2615 -3.2991,7.9006 1.2598,1.2796 -1.8335,1.5775 -1.8423,3.1547 -1.0919,1.3958 -2.4339,4.4325 -4.1379,4.2677 z m 8.993,-4.96 c 0.07,-1.5861 1.6215,-4.2909 1.6775,-6.3529 0.2509,-1.4521 -0.1866,-3.478 1.9651,-2.5548 2.3993,0.1652 4.7985,0.3337 7.1992,0.4774 -0.5289,1.9146 -1.6233,3.7423 -1.6991,5.7865 0.84,1.0277 3.2106,0.4312 3.5278,1.5374 -0.093,1.3625 -2.7125,0.3895 -3.7399,0.8206 -1.0883,0.1009 -3.5062,0.3932 -3.0308,-1.3508 -0.026,-1.5818 1.6101,-4.2327 -1.0281,-3.6342 -0.9697,0.4649 -1.0055,2.3543 -1.856,3.1893 -0.6592,1.0176 -1.5996,2.4356 -3.0157,2.0815 z m -20.1189,-1.7628 c -0.2007,-1.352 2.4944,-1.9231 3.2489,-3.0604 2.5219,-2.0801 4.9,-4.3511 6.9553,-6.8984 -1.0792,-1.1812 -2.1848,-2.3391 -3.2324,-3.5486 0.2924,-1.4452 1.3189,-0.3182 2.0441,0.075 0.8413,0.5214 1.6826,1.0429 2.5239,1.5643 1.4532,-1.958 2.6854,-4.1114 3.6479,-6.3501 -1.1911,-0.6479 -5.0092,-1.9764 -1.9139,-3.2085 2.1635,-0.8804 4.8286,-1.0343 5.983,1.4192 1.2833,1.0399 2.4989,4.4763 3.9649,1.9604 0.9531,-0.9351 1.1055,-2.3989 1.7038,-3.5683 0.7441,-1.3293 1.0731,-3.9055 2.1241,-4.3264 3.8257,2.6661 7.876,5.1593 11.0579,8.608 1.3526,3.1593 -3.1523,0.347 -4.3924,-0.2487 -1.66,-0.204 -4.0519,-3.8467 -5.0238,-1.3267 -0.1607,0.8248 -1.7442,1.8754 -0.7336,2.5335 2.0753,1.5343 4.1315,3.0445 6.3443,4.3748 4.2952,2.6309 8.8566,5.2889 13.9276,5.9074 0.022,2.0064 -3.6717,1.765 -5.2078,2.8054 -1.8109,0.6385 -3.6224,1.2755 -5.4324,1.9169 -3.6983,-3.6008 -7.411,-7.187 -11.077,-10.8208 -2.4984,0.983 -4.9893,1.9851 -7.4969,2.9445 -1.3257,-0.7868 0.1782,-1.2437 0.8565,-1.7051 1.5275,-0.972 3.1645,-1.8306 4.5857,-2.9232 -0.6419,-0.4117 -1.6964,-2.4734 -2.3937,-1.8828 -5.5558,7.1602 -12.7745,13.6123 -21.6634,16.1164 -0.3124,0.1966 -0.2675,-0.1823 -0.4006,-0.3578 z"/>
      <path id="path3354" d="m 37.35,55.3395 c -0.28,-0.5884 -1.6624,-1.2083 -0.3429,-1.4393 0.7916,-0.9146 1.5456,-1.8283 2.5118,-2.5828 1.1806,-1.1506 2.3262,-2.3528 3.1244,-3.8097 0.4062,-0.4147 0.8482,-0.95 1.4906,-0.8318 0.9983,-0.036 1.9967,-0.072 2.995,-0.1079 -2.0821,2.6357 -4.388,5.1032 -6.8648,7.3707 -0.9445,0.4343 -1.6967,1.8555 -2.6109,1.7967 -0.025,-0.1539 -0.3035,-0.2295 -0.3032,-0.3959 z m 0.7,-24.456 c -0.7214,-0.3823 -2.4501,-1.203 -0.896,-1.7513 1.176,-0.7135 2.4142,-1.3202 3.4941,-2.1832 1.3606,-0.8078 2.6094,-1.8015 4.0168,-2.5251 0.6321,-0.3057 1.307,-0.5024 1.9738,-0.7149 1.2022,1.0084 2.4825,2.0216 3.2852,3.3842 0.2727,1.4719 -1.9944,0.8245 -2.8343,1.2452 -2.0691,0.5086 -4.1008,1.1651 -6.0504,2.0255 -1.0493,0.1566 -2.0093,1.3824 -2.9892,0.5196 l 0,0 z"/>
    </g>
    <g id="white-dragon">
      <rect id="rect4376" height="69" width="45" y="6" x="13" fill="#BFBFBF"/>
      <rect id="rect4378" height="65" width="41" y="8" x="15" fill="#F4F4F4"/>
    </g>
    <!-- characters -->
    <g id="one-character">
      <path id="path4240" d="m43.8 18.1c-0.3 0.2-0.4 0.5-0.4 0.8s0.1 0.5 0.1 0.7c-2.6 0.2-19.7 1.8-23.9 1.4h-0.4l1.7 6 0.3-0.1c3.3-1.1 24.1-2.4 29-1.4 0.8 0.1 1.2 0 1.4-0.4 0.5-1-1.9-3.5-3.4-4.8-0.9-0.9-3.4-2.8-4.4-2.2z" fill="#20208C"/>
      <use id="use3814" xlink:href="#ten-thousand"/>
    </g>
    <g id="two-character">
      <path id="path4242" d="m43.9 23.9c-0.3 0.2-0.4 0.5-0.4 0.9 0 0.2 0 0.5 0.1 0.7-2.8 0.3-19.9 1.9-24.1 1.4l-0.5-0.1 1.7 6.2 0.4-0.1c3.3-1.2 24.3-2.4 29.3-1.4 0.8 0.2 1.3 0 1.5-0.4 0.7-1.3-3-4.6-3.4-4.9-1-1-3.5-3-4.6-2.3z" fill="#20208C"/>
      <path id="path4244" d="m36.1 12.9c-2.6 0.9-6.2 2.2-12.3 2.2h-0.7l2.9 4.2 16.7-2.2 0.5-3.1-0.1-0.1c-2.4-2.7-4.1-2.1-7-1z" fill="#20208C"/>
      <use id="use3816" xlink:href="#ten-thousand"/>
    </g>
    <g id="three-character">
      <path id="path4246" d="m43.7 26.3c-0.3 0.2-0.4 0.5-0.4 0.9 0 0.3 0 0.5 0.1 0.7-2.7 0.3-19.3 1.9-23.4 1.4l-0.5-0.1 1.7 6.2 0.3-0.1c3.2-1.2 23.6-2.4 28.4-1.4 0.8 0.2 1.3 0 1.5-0.4 0.6-1.3-2.9-4.6-3.3-5-1-0.8-3.4-2.9-4.4-2.2z" fill="#20208C"/>
      <polygon id="polygon4248" points="37.3 19 26 20.4 27.6 24.7 39.6 23.3 37.6 19" fill="#20208C"/>
      <path id="path4250" d="m34.9 8.6c-3 1.1-7 2.6-14 2.6h-0.6l3.2 4.9 18.9-2.6 0.6-3.6-0.1-0.1c-2.7-3.2-4.6-2.5-8-1.2z" fill="#20208C"/>
      <use id="use3818" xlink:href="#ten-thousand"/>
    </g>
    <g id="four-character">
      <path id="path3338" fill="#20208C" d="m 25.8,30.9 c -2.2,-6.4 -4.5,-12.8 -6.75,-19.1 1.8,0.3 3.6,0.8 5.4,1.2 0.5,1.97 1.08,3.9 1.75,5.86 0.82,2.89 1.47,5.82 2.28,8.72 1.22,-0.20 2.44,-0.55 3.58,-1.00 -0.19,-2.78 -0.40,-5.58 -1.04,-8.30 -0.01,-0.98 -0.82,-1.57 -1.50,-1.59 1.04,-0.35 2.11,-0.71 3.05,-1.27 0.54,-0.18 0.34,1.29 0.54,1.71 0.52,2.99 1.03,5.99 1.66,8.96 0.88,-0.21 2.81,0.17 2.60,-1.20 0.15,-3.12 0.36,-6.26 0.34,-9.39 0.42,-0.52 1.75,0.49 2.47,0.70 0.52,0.39 2.63,0.81 1.26,1.37 -1.06,1.05 -1.12,2.68 -1.41,4.07 -0.19,1.23 -0.31,2.47 -0.40,3.71 1.07,0.01 2.26,-0.08 3.19,0.53 0.39,0.82 1.30,1.83 0.75,2.75 -0.49,0.28 -1.43,1.65 -1.75,1.19 0.34,-1.35 -1.25,-1.56 -2.21,-1.47 -3.65,0.08 -7.20,1.11 -10.69,2.11 -0.99,0.29 -1.97,0.62 -2.96,0.94 -0.06,-0.18 -0.12,-0.37 -0.19,-0.56 z" />
      <path id="path3340" fill="#20208C" d="m 41.90,29.77 c 0.20,-1.22 0.92,-2.25 1.32,-3.40 1.48,-2.93 2.02,-6.22 2.43,-9.45 0.06,-0.39 0.13,-0.79 -0.30,-0.99 -1.06,-0.90 -2.58,-0.58 -3.86,-0.66 -3.53,-0.06 -6.99,0.73 -10.44,1.34 -1.28,0.29 -2.59,0.52 -3.85,0.90 -0.48,-0.05 -1.84,0.92 -1.59,-0.02 0.06,-1.00 0.12,-2.01 0.25,-3.01 3.99,-1.17 8.08,-2.03 12.23,-2.45 3.61,-0.29 7.42,-0.35 10.81,1.12 1.19,0.51 2.21,1.39 2.92,2.48 -1.56,4.71 -4.13,9.16 -7.70,12.64 -0.73,0.66 -1.45,1.36 -2.25,1.94 -0.01,-0.14 0.02,-0.28 0.04,-0.42 z" />
      <use id="use3820" xlink:href="#ten-thousand"/>
    </g>
    <g id="five-character">
      <path id="path4252" d="m29.8 10.3l-10.3 10.5 0.4 0.5 7-4c-0.6 1.5-4.3 11.6-4.3 11.6l3.3 3.5s2.4-15.6 2.4-15.9c0.3-0.2 5.1-2.9 5.1-2.9l-3.4-3.7-0.2 0.4z" fill="#20208C"/>
      <path id="path4254" d="m42.6 10.2h-1.9s-0.6 1.3-0.9 1.9l-0.1-0.1-5.9 3.5 0.2 0.7s3-0.2 3.9-0.2c-0.4 0.8-2.2 4.5-2.3 4.8-0.4 0-6.3 0.5-6.3 0.5l-0.1 0.7 4 1.6s0.7-0.3 1.3-0.5c-0.6 1.2-2.5 5.2-2.7 5.5-1.3 0.1-2.3 0.1-2.9 0h-0.4l0.5 3.7 0.3-0.1c1.4-0.2 12.2-1.6 14.1-1.7 1.8-0.1 7.3 2.1 7.4 2.1l0.7 0.3-0.2-0.7c-0.1-0.4-1.3-3.9-2.2-4.8l-0.1-0.1h-0.1c-0.8-0.2-3.6 0-7.5 0.4 0.9-1 4.3-4.6 4.3-4.6l-3.2-3.4s-2.9 7.8-3 8.2c-0.3 0-2.7 0.3-3.5 0.3 0.4-0.9 2.5-6.5 2.6-6.7 0.3-0.1 3.2-1.2 3.2-1.2l-0.2-0.7s-1.7 0.3-2.5 0.4c0.3-0.9 1.6-4.1 1.7-4.4 0.2 0 1.2-0.1 1.2-0.1s-0.6-0.9-0.7-1.1c0.1-0.3 1.7-4.4 1.7-4.4h-0.4z" fill="#20208C"/>
      <use id="use3822" xlink:href="#ten-thousand"/>
    </g>
    <g id="six-character">
      <path id="path4256" d="m33.2 9.8v1c0 1.6-0.2 3.7-0.7 6.2-5.9 0.7-11.1 1.5-11.2 1.5h-0.3v2.5s9.9-0.4 10.7-0.5c-0.2 0.7-1 4-1 4l0.6 0.3s2.9-4.1 3.1-4.4c11.7-0.3 14.4 0.2 15 0.5l0.6 0.4-0.6-3.5c-0.3-1-2-2.1-12.2-1.3 0.6-0.9 3.2-4.6 3.2-4.6l-7.2-2.7v0.6z" fill="#20208C"/>
      <path id="path4258" d="m27.6 24.8s0.8 4.7-1.6 8.5l0.5 0.5c4.4-2.9 5.9-6.6 5.9-6.7l0.1-0.3-5-2.6 0.1 0.6z" fill="#20208C"/>
      <path id="path4260" d="m37.1 23.7c0.2 0.3 5.9 7.7 7.9 9.6l0.1 0.1h0.2c0.4 0 0.8-0.3 1.1-0.7 0.8-1.1 1.3-3.2 1-4.3-0.4-1.3-7.6-4.3-9.8-5.2l-1.2-0.5 0.7 1z" fill="#20208C"/>
      <use id="use3824" xlink:href="#ten-thousand"/>
    </g>
    <g id="seven-character">
      <path id="path4262" d="m43.2 11.7c-0.2 0.4-1.5 1.9-8.3 7.6-0.1-0.7-0.2-1.6-0.2-1.6-0.2-1.9-0.4-4.1-0.8-6.5l-0.1-0.3-3.2 0.3v0.3 1.7c0 3.3 0.3 6.2 0.9 8.9-0.3 0.2-10 8.2-10 8.2l0.3 0.3 1.9 1.8s7.9-6.9 8.6-7.6c0.7 2.2 1.6 4 2.7 5 2 2 4.2 1.7 7 1.3 2-0.3 4.3-0.6 7-0.2l0.5 0.1-0.6-2.8c0-0.6-0.3-1.1-0.7-1.5-1.3-0.9-3.8-0.4-6.5 0.1-1.3 0.3-2.7 0.5-3.9 0.6-1.3-1.2-2.1-2.8-2.6-5.2 7.5-6.2 10.3-7.8 11.3-8.1l0.2-0.1v-0.3-0.4c0-1.8-0.9-2.8-1.7-3-0.5 0.1-1.3 0.3-1.8 1.4z" fill="#20208C"/>
      <use id="use3826" xlink:href="#ten-thousand"/>
    </g>
    <g id="eight-character">
      <path id="path4264" d="m24.4 19c0 3.7-4.5 9.2-4.7 9.4l-0.7 0.9 1.1-0.3c5.2-1.4 8.2-5 8.3-5.1l0.2-0.2-4.2-5.7v1z" fill="#20208C"/>
      <path id="path4266" d="m29.9 11.3l-2 0.3 0.3 0.5c0.1 0.2 9.3 15.7 10.6 19.3l0.1 0.3 0.3-0.1c2.2-0.4 4-0.2 5.8 0 2.2 0.2 4.3 0.4 6.7-0.4l0.4-0.1-0.2-0.4c-1.2-2-2.5-2.4-4.2-2.9-3.2-0.9-8-2.3-17.3-16.3l-0.1-0.2h-0.4z" fill="#20208C"/>
      <use id="use3828" xlink:href="#ten-thousand"/>
    </g>
    <g id="nine-character">
      <path id="path4268" d="m48.6 23.6s-2.9 3.2-3.1 3.4c-3.2 0.7-8.4 1.2-8.8-0.4-0.5-1.9 3.4-10.4 4.9-13.6l0.2-0.3-5.6-2.8-0.1 0.4c-0.1 0.2-0.4 1.3-0.9 3h-4.5c0-0.4-0.1-1.3-0.1-1.3-1.4-2.3-7.4-0.7-8.1-0.6l-0.4 0.1 0.2 0.4c0.2 0.4 0.4 0.9 0.5 1.4h-3.8l1.9 3.6s1.8-0.3 2.4-0.4v0.7c0 6.2-2.7 14.1-2.7 14.2l0.6 0.3c0.3-0.4 7.9-9.5 9.3-16.4 0.2 0 2.4-0.4 4.4-0.7-1.2 4.7-2.6 12.1-0.3 14.8 3.4 4 16.6 3.7 17.1 3.5l0.3-0.1-3.4-9.2z" fill="#20208C"/>
      <use id="use3830" xlink:href="#ten-thousand"/>
    </g>
    <!-- bamboo -->
    <g id="one-bamboo">
      <use id="use4058" xlink:href="#bamboo" stroke="#006C00" transform="translate(29 25) scale(1.18 1.15)"/>
    </g>
    <g id="two-bamboo">
      <use id="use4062" xlink:href="#bamboo" stroke="#006C00" transform="translate(30 9.5)"/>
      <use id="use4064" xlink:href="#bamboo" stroke="#006C00" transform="translate(30 44.5)"/>
    </g>
    <g id="three-bamboo">
      <use id="use4070" xlink:href="#bamboo" stroke="#006C00" transform="translate(18 44.5)"/>
      <use id="use4074" xlink:href="#bamboo" stroke="#006C00" transform="translate(30 9.5)"/>
      <use id="use4078" xlink:href="#bamboo" stroke="#006C00" transform="translate(41 44.5)"/>
    </g>
    <g id="four-bamboo">
      <use id="use4082" xlink:href="#bamboo" stroke="#006C00" transform="translate(18 9.5)"/>
      <use id="use4084" xlink:href="#bamboo" stroke="#006C00" transform="translate(18 44.5)"/>
      <use id="use4090" xlink:href="#bamboo" stroke="#006C00" transform="translate(42 9.5)"/>
      <use id="use4092" xlink:href="#bamboo" stroke="#006C00" transform="translate(42 44.5)"/>
    </g>
    <g id="five-bamboo">
      <use id="use4098" xlink:href="#bamboo" stroke="#006C00" transform="translate(18 10.5) scale(.91 .925)"/>
      <use id="use4100" xlink:href="#bamboo" stroke="#006C00" transform="translate(18 45.5) scale(.91 .925)"/>
      <use id="use4108" xlink:href="#bamboo" stroke="#9C0000" transform="translate(30.5 28) scale(.91 .925)"/>
      <use id="use4110" xlink:href="#bamboo" stroke="#006C00" transform="translate(43 10.5) scale(.91 .925)"/>
      <use id="use4112" xlink:href="#bamboo" stroke="#006C00" transform="translate(43 45.5) scale(.91 .925)"/>
    </g>
    <g id="six-bamboo">
      <use id="use4118" xlink:href="#bamboo" stroke="#006C00" transform="translate(19 12.5) scale(.82 .85)"/>
      <use id="use4120" xlink:href="#bamboo" stroke="#006C00" transform="translate(19 45.5) scale(.82 .85)"/>
      <use id="use4126" xlink:href="#bamboo" stroke="#006C00" transform="translate(31 12.5) scale(.82 .85)"/>
      <use id="use4128" xlink:href="#bamboo" stroke="#006C00" transform="translate(31 45.5) scale(.82 .85)"/>
      <use id="use4134" xlink:href="#bamboo" stroke="#006C00" transform="translate(43 12.5) scale(.82 .85)"/>
      <use id="use4136" xlink:href="#bamboo" stroke="#006C00" transform="translate(43 45.5) scale(.82 .85)"/>
    </g>
    <g id="seven-bamboo">
      <use id="use4142" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 31.5) scale(.73 .66)"/>
      <use id="use4144" xlink:href="#bamboo" stroke="#006C00" transform="translate(31.5 31.5) scale(.73 .66)"/>
      <use id="use4146" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 31.5) scale(.73 .66)"/>
      <use id="use4148" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 50.5) scale(.73 .66)"/>
      <use id="use4150" xlink:href="#bamboo" stroke="#006C00" transform="translate(31.5 50.5) scale(.73 .66)"/>
      <use id="use4152" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 50.5) scale(.73 .66)"/>
      <use id="use4166" xlink:href="#bamboo" stroke="#9C0000" transform="translate(31.5 12.5) scale(.73 .66)"/>
    </g>
    <g id="eight-bamboo">
      <use id="use4170" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 13.5) scale(.73 .77)"/>
      <use id="use4172" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 46.5) scale(.73 .77)"/>
      <use id="use4178" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 13.5) scale(.73 .77)"/>
      <use id="use4180" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 46.5) scale(.73 .77)"/>
      <use id="use4182" xlink:href="#bamboo-rgt" stroke="#006C00" transform="translate(28.0 14.0) scale(.77 .77)"/>
      <use id="use4184" xlink:href="#bamboo-lft" stroke="#006C00" transform="translate(35.0 14.0) scale(.77 .77)"/>
      <use id="use4182" xlink:href="#bamboo-rgt" stroke="#006C00" transform="translate(35.0 47.0) scale(.77 .77)"/>
      <use id="use4184" xlink:href="#bamboo-lft" stroke="#006C00" transform="translate(28.0 47.0) scale(.77 .77)"/>
    </g>
    <g id="nine-bamboo">
      <use id="use4186" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 12.5) scale(.73 .66)"/>
      <use id="use4188" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 31.5) scale(.73 .66)"/>
      <use id="use4190" xlink:href="#bamboo" stroke="#006C00" transform="translate(19.5 50.5) scale(.73 .66)"/>
      <use id="use4198" xlink:href="#bamboo" stroke="#9C0000" transform="translate(31.5 12.5) scale(.73 .66)"/>
      <use id="use4200" xlink:href="#bamboo" stroke="#9C0000" transform="translate(31.5 31.5) scale(.73 .66)"/>
      <use id="use4202" xlink:href="#bamboo" stroke="#9C0000" transform="translate(31.5 50.5) scale(.73 .66)"/>
      <use id="use4210" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 12.5) scale(.73 .66)"/>
      <use id="use4212" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 31.5) scale(.73 .66)"/>
      <use id="use4214" xlink:href="#bamboo" stroke="#006C00" transform="translate(43.5 50.5) scale(.73 .66)"/>
    </g>
    <!-- season tiles -->
    <g id="season-1"> <!-- 2112 -->
      <use id="use3850" y="6" x="13" xlink:href="#season"/>
      <path id="path4428" stroke="#678ED3" d="m27.6 16.1c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.8 0.2 9.9-0.6 9.9-0.6z" fill="#99B9FF"/>
    </g>
    <g id="season-2"> <!-- 2176 -->
      <use id="use3852" y="6" x="13" xlink:href="#season"/>
      <path id="path4434" stroke="#678ED3" d="m27.6 18.9c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.8 0.2 9.9-0.6 9.9-0.6z" fill="#99B9FF"/>
      <path id="path4436" stroke="#678ED3" d="m27.1 14.5c-2-2.3-2.8 0.6-9 0.6l1.1 1.7 7.7-1 0.2-1.3z" fill="#99B9FF"/>
    </g>
    <g id="season-3"> <!-- 2240 -->
      <use id="use3854" y="6" x="13" xlink:href="#season"/>
      <path id="path4426" stroke="#678ED3" d="m27.6 19.9c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.8 0.2 9.9-0.6 9.9-0.6z" fill="#99B9FF"/>
      <polygon id="polygon4430" stroke="#678ED3" points="24.9 16.3 25.7 17.8 20.9 18.3 20.4 16.8" fill="#99B9FF"/>
      <path id="path4432" stroke="#678ED3" d="m27.1 12.5c-2-2.3-2.8 0.6-9 0.6l1.1 1.7 7.7-1 0.2-1.3z" fill="#99B9FF"/>
    </g>
    <g id="season-4"> <!-- 2304 -->
      <use id="use3856" y="6" x="13" xlink:href="#season"/>
      <path id="path4424" stroke="#678ED3" d="m19.8 13.9l-0.1 1.3s8.9-2.4 9.4-0.6c0 0-0.4 4.1-1.4 4.9 0-0.5-0.7-0.6-1.7-0.5 0.1-1.1 0.3-3.7 1-4l-1.6-0.7-0.2 4.8-1.5 0.3-0.9-4.8-1 0.4 0.9 4.7c-1.1 0.3-2 0.5-2 0.5l-1.8-7-2.2-0.5 3.1 8.9s7.7-2.7 7.5-0.7c3.2-2.5 4.3-6.5 4.3-6.5-2.2-3.4-11.8-0.5-11.8-0.5z" fill="#99B9FF"/>
    </g>
    <!-- flower tiles -->
    <g id="flower-1"> <!-- 2432 -->
      <use id="use3866" y="6" x="13" xlink:href="#flower"/>
      <path id="path4456" stroke="#7C5A2D" stroke-width=".5" d="m26.9 22.5c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.9 0.2 9.9-0.6 9.9-0.6z" fill="#DBC879"/>
    </g>
    <g id="flower-2"> <!-- 2496 -->
      <use id="use3868" y="6" x="13" xlink:href="#flower"/>
      <path id="path4462" stroke="#7C5A2D" stroke-width=".5" d="m26.9 25.3c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.9 0.2 9.9-0.6 9.9-0.6z" fill="#DBC879"/>
      <path id="path4464" stroke="#7C5A2D" stroke-width=".5" d="m26.5 20.8c-2-2.3-2.8 0.6-9 0.6l1.1 1.7 7.7-1 0.2-1.3z" fill="#DBC879"/>
    </g>
    <g id="flower-3"> <!-- 2560 -->
      <use id="use3870" y="6" x="13" xlink:href="#flower"/>
      <path id="path4454" stroke="#7C5A2D" stroke-width=".5" d="m26.9 26.3c-0.8-2.5 4.7 2.6 2.6 2.2s-10.6 0.1-11.9 0.6l-0.6-2.2c1.9 0.2 9.9-0.6 9.9-0.6z" fill="#DBC879"/>
      <polygon id="polygon4458" stroke="#7C5A2D" stroke-width=".5" points="24.3 22.6 25 24.1 20.3 24.7 19.7 23.2" fill="#DBC879"/>
      <path id="path4460" stroke="#7C5A2D" stroke-width=".5" d="m26.5 18.8c-2-2.3-2.8 0.6-9 0.6l1.1 1.7 7.7-1 0.2-1.3z" fill="#DBC879"/>
    </g>
    <g id="flower-4"> <!-- 2624 -->
      <use id="use3872" y="6" x="13" xlink:href="#flower"/>
      <path id="path4452" stroke="#7C5A2D" stroke-width=".5" d="m19.1 20.3l-0.1 1.3s8.9-2.4 9.4-0.6c0 0-0.4 4.1-1.4 4.9 0-0.5-0.7-0.6-1.7-0.5 0.1-1.1 0.3-3.7 1-4l-1.6-0.7-0.2 4.8-1.5 0.3-0.9-4.8-1 0.4 0.9 4.7c-1.1 0.3-2 0.5-2 0.5l-1.8-7-2.2-0.6 3.1 8.9s7.7-2.7 7.5-0.7c3.2-2.5 4.3-6.5 4.3-6.5-2.2-3.3-11.8-0.4-11.8-0.4z" fill="#DBC879"/>
    </g>
  </defs>
  <!-- tile decorations on transparent background -->
  <use id="use5000" y="0" x="0" xlink:href="#one-coin"/>
  <use id="use5002" y="0" x="64" xlink:href="#two-coins"/>
  <use id="use5004" y="0" x="128" xlink:href="#three-coins"/>
  <use id="use5006" y="0" x="192" xlink:href="#four-coins"/>
  <use id="use5008" y="0" x="256" xlink:href="#five-coins"/>
  <use id="use5010" y="0" x="320" xlink:href="#six-coins"/>
  <use id="use5012" y="0" x="384" xlink:href="#seven-coins"/>
  <use id="use5014" y="0" x="448" xlink:href="#eight-coins"/>
  <use id="use5016" y="0" x="512" xlink:href="#nine-coins"/>
  <use id="use5020" y="0" x="576" xlink:href="#north-wind"/>
  <use id="use5022" y="0" x="640" xlink:href="#west-wind"/>
  <use id="use5024" y="0" x="704" xlink:href="#south-wind"/>
  <use id="use5026" y="0" x="768" xlink:href="#east-wind"/>
  <use id="use5028" y="0" x="832" xlink:href="#red-dragon"/>
  <use id="use5030" y="0" x="896" xlink:href="#green-dragon"/>
  <use id="use5032" y="0" x="960" xlink:href="#one-character"/>
  <use id="use5034" y="0" x="1024" xlink:href="#two-character"/>
  <use id="use5036" y="0" x="1088" xlink:href="#three-character"/>
  <use id="use5038" y="0" x="1152" xlink:href="#four-character"/>
  <use id="use5040" y="0" x="1216" xlink:href="#five-character"/>
  <use id="use5042" y="0" x="1280" xlink:href="#six-character"/>
  <use id="use5044" y="0" x="1344" xlink:href="#seven-character"/>
  <use id="use5046" y="0" x="1408" xlink:href="#eight-character"/>
  <use id="use5048" y="0" x="1472" xlink:href="#nine-character"/>
  <use id="use5050" y="0" x="1536" xlink:href="#one-bamboo"/>
  <use id="use5052" y="0" x="1600" xlink:href="#two-bamboo"/>
  <use id="use5054" y="0" x="1664" xlink:href="#three-bamboo"/>
  <use id="use5056" y="0" x="1728" xlink:href="#four-bamboo"/>
  <use id="use5058" y="0" x="1792" xlink:href="#five-bamboo"/>
  <use id="use5060" y="0" x="1856" xlink:href="#six-bamboo"/>
  <use id="use5062" y="0" x="1920" xlink:href="#seven-bamboo"/>
  <use id="use5064" y="0" x="1984" xlink:href="#eight-bamboo"/>
  <use id="use5066" y="0" x="2048" xlink:href="#nine-bamboo"/>
  <use id="use5068" y="0" x="2112" xlink:href="#season-1"/>
  <use id="use5070" y="0" x="2176" xlink:href="#season-2"/>
  <use id="use5072" y="0" x="2240" xlink:href="#season-3"/>
  <use id="use5074" y="0" x="2304" xlink:href="#season-4"/>
  <use id="use5076" y="0" x="2368" xlink:href="#white-dragon"/>
  <use id="use5078" y="0" x="2432" xlink:href="#flower-1"/>
  <use id="use5080" y="0" x="2496" xlink:href="#flower-2"/>
  <use id="use5082" y="0" x="2560" xlink:href="#flower-3"/>
  <use id="use5084" y="0" x="2624" xlink:href="#flower-4"/>
  <!-- plain tile background -->
  <use id="use3726" y="0" x="2688" xlink:href="#plain-tile"/>
  <!-- selected tile background -->
  <use id="use3728" y="0" x="2752" xlink:href="#selected-tile"/>
</svg>
}
