module ProfileView
export root

global root

# If IJulia is available, don't use TK
useTk = true
if isdefined(Main, :IJulia)
    useTk = false
else
    using Tk, Color, Base.Graphics
    import Cairo
end
using Color, Base.Graphics

import Base: contains, isequal, show

include("tree.jl")
include("pvtree.jl")

if useTk
    include(joinpath(Pkg.dir(), "ImageView", "src", "rubberband.jl")) # for zoom
end

using .Tree
using .PVTree

immutable TagData
    ip::Uint
    status::Int
end
TagData(ip::Integer, status::Integer) = TagData(uint(ip), int(status))
const TAGNONE = TagData(0, -1)

const bkg = color("black")
const fontcolor = color("white")
const gccolor = color("red")
const colors = distinguishable_colors(13, [bkg,fontcolor,gccolor])[4:end]

if useTk
    type ZoomCanvas
        bb::BoundingBox  # in user-coordinates
        c::Canvas
    end
end

function view(data = Profile.fetch(); C = false, colorgc = true, fontsize = 12, combine = true, svgout::IO = DevNull, Tk::Bool = useTk)
    if isdefined(Main, :IJulia) && svgout == DevNull
        svgout = STDOUT  # FIXME: need to hook this up to IJulia properly
    end
    if svgout != DevNull
        viewsvg(svgout, data, C = false, colorgc = true, fontsize = 12, combine = true)
    elseif Tk
        viewtk(data, C = false, colorgc = true, fontsize = 12, combine = true)
    else
        warn("No output enabled: Must set \"Tk=true\" or \"svgout=<IO_handle>\" to get Profiler output")
    end
end

function preprocess(data, C, colorgc, combine)
        bt, counts = Profile.tree_aggregate(data)
        if isempty(counts)
            Profile.warning_empty()
            return
        end
        len = Int[length(x) for x in bt]
        keep = len .> 0
        bt = bt[keep]
        counts = counts[keep]
        # Do code address lookups on all unique instruction pointers
        uip = unique(vcat(bt...))
        nuip = length(uip)
        lkupdict = Dict(uip, 1:nuip)
        lkupC = [Profile.lookup(ip, true) for ip in uip]
        lkupJ = [Profile.lookup(ip, false) for ip in uip]
        lidict = Dict(uip, lkupC)
        isjl = Dict(uip, [lkupC[i].line == lkupJ[i].line for i = 1:nuip])
        isgc = Dict(uip, [lkupC[i].func == "jl_gc_collect" for i = 1:nuip])
        isjl[uint(0)] = false  # needed for root below
        isgc[uint(0)] = false
        p = Profile.liperm(lkupC)
        rank = similar(p)
        rank[p] = 1:length(p)
        ip2so = Dict(uip, rank)
        so2ip = Dict(rank, uip)
        # Build the graph
        level = 0
        w = sum(counts)
        root = Tree.Node(PVData(1:w))
        PVTree.buildgraph!(root, bt, counts, 0, ip2so, so2ip, lidict)
        PVTree.setstatus!(root, isgc)
    #     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", hspan = ", x.hspan, ", status = ", x.status))
    #     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", status = ", x.status))
    #     Tree.showedges(STDOUT, root, x -> x.status == 0 ? nothing : string(get(lidict, x.ip, "root"), ", status = ", x.status))
    #     checkidentity(ip2so, so2ip)
    #     checkcontains(root, ip2so, so2ip, lidict)
    #     checkstatus(root, isgc, isjl, C, lidict)
        counts = zeros(Int, length(uip))
        if !C
            PVTree.prunegraph!(root, isjl, lidict, ip2so, counts)
        end
    #     for ip in uip
    #         println(counts[ip2so[ip]], ": ", lidict[ip])
    #     end
    #     if !C
    #         havegc = any([isgc[ip] for ip in uip])
    #         if havegc
    #             @assert checkprunedgc(root, false)
    #         end
    #     end
    #     println("\nPruned:")
    #     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", status = ", x.status))
        function child_samples!(lkchildsamples, parent)
            samples = 0
            for child in parent
                samples += length(child.data.hspan)
            end
            if haskey(lkupdict, parent.data.ip)
                lkchildsamples[parent.data.ip] = samples
            end
            for child in parent
                child_samples!(lkchildsamples, child)
            end
        end
        lkchildsamples = Dict(uip, zeros(Int, nuip))
        child_samples!(lkchildsamples, root)
        # Generate a "tagged" image
        rowtags = {fill(TAGNONE, w)}
        buildtags!(rowtags, root, 1)
        imgtags = hcat(rowtags...)
        img = buildimg(imgtags, colors, bkg, gccolor, colorgc, combine, lidict)
        return img, imgtags, lidict, lkchildsamples, rowtags
end

function viewtk(data = Profile.fetch(); C = false, colorgc = true, fontsize = 12, combine = true)
    img, imgtags, lidict, lkchildsamples, rowtags = preprocess(data, C, colorgc, combine)
    img24 = [convert(Uint32, convert(RGB24, img[i,j])) for i = 1:size(img,1), j = size(img,2):-1:1]'
    surf = Cairo.CairoRGBSurface(img24)
    imw = size(img24,2)
    imh = size(img24,1)
    # Display in a window
    win = Toplevel("Profile", 300, 300)
    f = Frame(win)
    pack(f, expand = true, fill = "both")
    c = Canvas(f)
    pack(c, expand = true, fill = "both")
    czoom = ZoomCanvas(BoundingBox(0, imw, 0, imh), c)
    c.mouse.button1press = (c, x, y) -> rubberband_start(c, x, y, (c, bb) -> zoom_bb(czoom, bb))
    bind(c, "<Double-Button-1>", (path,x,y)->zoom_reset(czoom))
    lasttextbb = BoundingBox(1,0,1,0)
    imgbb = BoundingBox(0, imw, 0, imh)
    function zoom_bb(czoom::ZoomCanvas, bb::BoundingBox)
        czoom.bb = bb & imgbb
        redraw(czoom.c)
        reveal(czoom.c)
        Tk.update()
    end
    function zoom_reset(czoom::ZoomCanvas)
        czoom.bb = imgbb
        redraw(czoom.c)
        reveal(czoom.c)
        Tk.update()
    end
    function redraw(c)
        ctx = getgc(c)
        w = width(c)
        h = height(c)
        cbb = czoom.bb
        winbb = BoundingBox(0, w, 0, h)
        set_coords(ctx, winbb, cbb)
        rectangle(ctx, cbb)
        set_source(ctx, surf)
        p = Cairo.get_source(ctx)
        Cairo.pattern_set_filter(p, Cairo.FILTER_NEAREST)
        fill(ctx)
    end
    # From a given position, find the underlying tag
    function gettag(xu, yu)
        x = iceil(xu)
        y = iceil(yu)
        Y = size(imgtags, 2)
        x = max(1, min(x, size(imgtags, 1)))
        y = max(1, min(y, Y))
        imgtags[x,Y-y+1]
    end
    c.resize = function (_)
        redraw(c)
        reveal(c)
        Tk.update()
    end
    # Hover over a block and see the source line
    c.mouse.motion = function (c, xd, yd)
        # Repair image from ovewritten text
        ctx = getgc(c)
        w = width(c)
        if width(lasttextbb) > 0
            h = height(c)
            winbb = BoundingBox(0, w, 0, h)
            set_coords(ctx, winbb, czoom.bb)
            rectangle(ctx, lasttextbb)
            set_source(ctx, surf)
            p = Cairo.get_source(ctx)
            Cairo.pattern_set_filter(p, Cairo.FILTER_NEAREST)
            fill(ctx)
        end
        # Write the info
        xu, yu = device_to_user(ctx, xd, yd)
        tag = gettag(xu, yu)
        if tag != TAGNONE
            li = lidict[tag.ip]
            str = string(basename(li.file), ", ", li.func, ": line ", li.line)
            set_source(ctx, fontcolor)
            Cairo.set_font_face(ctx, "sans-serif $(fontsize)px")
            lasttextbb = Cairo.text(ctx, xu, yu, str, halign = xd < w/3 ? "left" : xd < 2w/3 ? "center" : "right")
        end
        reveal(c)
        Tk.update()
    end
    # Right-click prints the full path, function, and line to the console
    c.mouse.button3press = function (c, xd, yd)
        ctx = getgc(c)
        xu, yu = device_to_user(ctx, xd, yd)
        tag = gettag(xu, yu)
        if tag != TAGNONE
            li = lidict[tag.ip]
            println(li.file, ", ", li.func, ": line ", li.line)
        end
    end
    set_size(win, 300, 300)
    c.resize(c)
    nothing
end



function svgheader(io::IO; width=1200, height=706, font="Verdana")
    y_msg = height - 17
    print(io, """<?xml version="1.0" standalone="no"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" width="$(width)" height="$(height)" onload="init(evt)" viewBox="0 0 $(width) $(height)" xmlns="http://www.w3.org/2000/svg" >
<defs >
    <linearGradient id="background" y1="0" y2="1" x1="0" x2="0" >
        <stop stop-color="#eeeeee" offset="5%" />
        <stop stop-color="#eeeeb0" offset="95%" />
    </linearGradient>
</defs>
<style type="text/css">
    rect[rx]:hover { stroke:black; stroke-width:1; }
    text:hover { stroke:black; stroke-width:1; stroke-opacity:0.35; }
</style>
<script type="text/ecmascript">
<![CDATA[
    var details;
    function init(evt) { details = document.getElementById("details").firstChild; }
    function s(info) { details.nodeValue = info; }
    function c() { details.nodeValue = ' '; }
]]>
</script>
<rect x="0.0" y="0" width="$(width).0" height="$(height).0" fill="url(#background)"  />
<text text-anchor="middle" x="600" y="24" font-size="17" font-family="$(font)" fill="rgb(0,0,0)"  >Flame Graph</text>
<text text-anchor="left" x="10" y="$y_msg" font-size="12" font-family="$(font)" fill="rgb(0,0,0)"  >Function:</text>
<text text-anchor="" x="70" y="$y_msg" font-size="12" font-family="$(font)" fill="rgb(0,0,0)" id="details" > </text>
""")
end

function viewsvg(io::IO, data = Profile.fetch(); C = false, colorgc = true, fontsize = 12, combine = true)
    img, imgtags, lidict, lkchildsamples, rowtags = preprocess(data, C, colorgc, combine)
    ncols, nrows = size(img)
    leftmargin = rightmargin = 10
    width = 1200
    topmargin = 30
    botmargin = 40
    rowheight = 15
    height = ceil(rowheight*nrows + botmargin + topmargin)
    xstep = (width - (leftmargin + rightmargin)) / ncols
    ystep = (height - (topmargin + botmargin)) / nrows
    avgcharwidth = 6  # for Verdana 12 pt font (FIXME: chars are different widths and caller can change font size)
    function eschtml(str)
        s = replace(str, '<', "&lt;")
        s = replace(s, '>', "&gt;")
        s = replace(s, '&', "&amp;")
        s
    end
    function printrec(io, samples, lidict, xstart, xend, y, tag, rgb)
        width = xend - xstart
        li = lidict[tag.ip]
        self = samples - lkchildsamples[tag.ip]
        selfpct = round(100*self/samples,1)
        samplepct = round(100*samples/ncols,1)
        info = "$(li.func) in $(li.file):$(li.line): $(samplepct)% of all samples ($(selfpct)% in self; $(100-selfpct)% in children)"
        shortinfo = info
        if avgcharwidth*3 > width
            shortinfo = ""
        elseif length(shortinfo) * avgcharwidth > width
            nchars = int(width/avgcharwidth)-2
            shortinfo = eschtml(info[1:nchars] * "..")
        end
        info = eschtml(info)
        red = iround(selfpct * 180 /100) + 86
        green = iround(samplepct * 90 / 100) + 90
        blue = 70
        print(io, """<rect x="$xstart" y="$y" width="$width" height="$ystep" fill="rgb($red,$green,$blue)" rx="2" ry="2" onmouseover="s('$info')" onmouseout="c()"/>""")
        if shortinfo != ""
            println(io, """\n<text text-anchor="" x="$(xstart+4)" y="$(y+11.5)" font-size="12" font-family="Verdana" fill="rgb(0,0,0)" onmouseover="s('$info')" onmouseout="c()">\n$shortinfo\n</text>""")
        end
    end
    svgheader(io, width=width, height=height)
    # rectangles are on a grid and split across multiple columns (must span similar adjacent ones together)
    for r in 1:nrows
        # top of rectangle:
        y = height - r*ystep - botmargin
        # local vars:
        prevtag = TAGNONE
        xstart = xend = 0.0
        for c in 1:ncols
            tag = rowtags[r][c]
            if prevtag == TAGNONE && prevtag != tag
                # Very first in span
                xstart = (c-1) * xstep + leftmargin
            elseif tag != prevtag && tag != TAGNONE && prevtag != TAGNONE
                # End of old span and start of new one
                xend = (c-1) * xstep + leftmargin
                samples = int(round((xend - xstart)/xstep))
                printrec(io, samples, lidict, xstart, xend, y, prevtag, img[c-1,r])
                xstart = xend
            elseif tag == TAGNONE && tag != prevtag
                # at end of span and start of nothing
                xend = (c-1) * xstep + leftmargin
                samples = int(round((xend - xstart)/xstep))
                printrec(io, samples, lidict, xstart, xend, y, prevtag, img[c-1,r])
                xstart = 0.0
            elseif c == ncols && tag != TAGNONE
                # end of span at last element of row
                xend = (c-1) * xstep + leftmargin
                samples = int(round((xend - xstart)/xstep))
                printrec(io, samples, lidict, xstart, xend, y, tag, img[c,r])
                xstart = 0.0
            else
                # in middle of span
            end
            prevtag = tag
        end
    end
    println(io, "\n</svg>")
end
    

function buildtags!(rowtags, parent, level)
    if isleaf(parent)
        return
    end
    w = length(rowtags[1])
    if length(rowtags) < level
        push!(rowtags, fill(TAGNONE, w))
    end
    t = rowtags[level]
    for c in parent
        t[c.data.hspan] = TagData(c.data.ip, c.data.status)
        buildtags!(rowtags, c, level+1)
    end
end

function buildimg(imgtags, colors, bkg, gccolor, colorgc::Bool, combine::Bool, lidict)
    w = size(imgtags,1)
    h = size(imgtags,2)
    img = fill(bkg, w, h)
    colorlen = int(length(colors)/2)
    for j = 1:h
        coloroffset = colorlen*iseven(j)
        colorindex = 1
        lasttag = TAGNONE
        status = 0
        first = 0
        nextcolor = colors[coloroffset + colorindex]
        for i = 1:w
            t = imgtags[i,j]
            if t != TAGNONE
                if t != lasttag && (lasttag == TAGNONE || !(combine && lidict[lasttag.ip] == lidict[t.ip]))
                    if first != 0
                        colorindex = fillrow!(img, j, first:i-1, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
                        nextcolor = colors[coloroffset + colorindex]
                        status = t.status
                    end
                    first = i
                    lasttag = t
                else
                    status |= t.status
                end
            else
                if first != 0
                    # We transitioned from tag->none, render the previous range
                    colorindex = fillrow!(img, j, first:i-1, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
                    nextcolor = colors[coloroffset + colorindex]
                    first = 0
                    lasttag = TAGNONE
                end
            end
        end
        if first != 0
            # We got to the end of a row, render the previous range
            fillrow!(img, j, first:w, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
        end
    end
    img
end

function fillrow!(img, j, rng::Range1{Int}, colorindex, colorlen, regcolor, gccolor, status)
    if status > 0
        img[rng,j] = gccolor
        return colorindex
    else
        img[rng,j] = regcolor
        return mod1(colorindex+1, colorlen)
    end
end

#### Debugging code

function checkidentity(ip2so, so2ip)
    for (k,v) in ip2so
        @assert so2ip[v] == k
    end
end

function checkcontains(root, ip2so, so2ip, lidict)
    flag = contains(root, ip2so)
    if !all(flag)
        missing = find(!flag)
        println("missing ips:")
        for i in missing
            println(lidict[so2ip[i]])
        end
        error("Internal error: the tree does not contain all ips")
    end
end

# This skips the parent, gets everything else
# (to avoid a problem with root with ip=0)
function contains(parent::Node, ip2so::Dict)
    ret = Array(Bool, 0)
    contains!(ret, parent, ip2so)
    return ret
end

function contains!(ret, parent::Node, ip2so::Dict)
    for c in parent
        indx = ip2so[c.data.ip]
        setindexsafe!(ret, indx, true)
        contains!(ret, c, ip2so)
    end
end

function setindexsafe!(a, i::Integer, val)
    if i > length(a)
        insert!(a, i, val)
    else
        a[i] = val
    end
end

function checkstatus(parent::Node, isgc::Dict, isjl::Dict, C, lidict)
    if isgc[parent.data.ip] && parent.data.status == 0
            @show lidict[parent.data.ip]
            error("gc should be set, and it isn't")
    end
    for c in parent
        checkstatus(c, isgc, isjl, C, lidict)
    end
end

function checkprunedgc(parent::Node, tf::Bool)
    tf |= parent.data.status > 0
    if !tf
        for c in parent
            tf = checkprunedgc(c, tf)
        end
    end
    tf
end

end
