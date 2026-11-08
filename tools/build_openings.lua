--[[--
Convert the lichess-org/chess-openings lists into the plugin's data file.

The source (https://github.com/lichess-org/chess-openings, CC0) gives each
opening as ECO code, name and a line in SAN. The device wants the line as
UCI moves, which it can replay without parsing notation, and a key for the
position it ends in, so a game that reaches it by another move order is
still recognised. Both are worked out here with the plugin's own board and
SAN parser, which also proves every line is legal.

    luajit tools/build_openings.lua a.tsv b.tsv c.tsv d.tsv e.tsv > out.tsv

tools/build_openings.sh downloads the lists and runs this.

Output, one opening per line:
    ECO <TAB> name <TAB> UCI moves <TAB> key <TAB> the line in SAN, as given
--]]--

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../kobochess.koplugin/?.lua;" .. package.path

local Pgn = require("kobochess.pgn")

local count, bad = 0, 0
for _, path in ipairs(arg) do
    local f = assert(io.open(path, "r"))
    local header = true
    for line in f:lines() do
        if header then
            header = false
        else
            local eco, name, line_text = line:match("^(%S+)\t([^\t]+)\t([^\t]+)")
            if eco then
                local sans = Pgn.lineToSans(line_text)
                local board, _, ucis = Pgn.playSans(sans)
                if board then
                    io.write(eco, "\t", name, "\t", table.concat(ucis, " "), "\t",
                             Pgn.positionKey(board), "\t", line_text, "\n")
                    count = count + 1
                else
                    io.stderr:write(("skipped %s %s: move %s\n"):format(eco, name, tostring(_)))
                    bad = bad + 1
                end
            end
        end
    end
    f:close()
end
io.stderr:write(("%d openings written, %d skipped\n"):format(count, bad))
