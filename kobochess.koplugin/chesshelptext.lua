--[[--
What each training button does: the explanation shown the first time it is
used (chesshelpdialog.lua), until "Do not show this again".

@module kobochess.chesshelptext
--]]

local _ = require("gettext")

return {
    train = {
        title = _("Train"),
        text = _("Train opens chess training, on a board of its own. Your game is kept as it is and waits for you.\n\n• Puzzles: find the best move in positions from real games\n• Puzzle of the day: one puzzle, the same all day\n• Famous games: play through great games of the past, or guess the moves\n• Openings: learn the first moves of an opening by heart\n\n\"Back to the game\" in the training menus returns to your game."),
    },
    train_refresh = {
        title = _("Refresh"),
        text = _("Refresh flashes the whole screen black and white once.\n\nE-ink keeps faint traces (ghosts) of what was on it before, especially after menus and dialogs. A flash clears them."),
    },

    -- Puzzles
    puzzle_menu = {
        title = _("Puzzle menu"),
        text = _("The puzzle menu holds:\n\n• Next puzzle: a new one, close to your puzzle rating\n• Puzzle of the day\n• Try again: the same puzzle from the start\n• Flip board\n• Your puzzle stats: your rating, how many you solved, your best run\n\nYour puzzle rating starts at 1200. It goes up when you solve a puzzle without a mistake or a hint, more for a hard puzzle, and down when you do not, so the puzzles you get stay close to your level."),
    },
    puzzle_hint = {
        title = _("Hint"),
        text = _("Hint shows which piece to move: it is picked up for you. Tap Hint again to see where it goes too.\n\nThe puzzle still counts as done, but not as solved cleanly, so your puzzle rating goes down a little."),
    },
    puzzle_solution = {
        title = _("Solution"),
        text = _("Solution plays the right move for you, and the answer that follows. Tap it again for the next move, until the puzzle is finished.\n\nUse it when you are stuck: seeing the idea is how you learn it. It counts as not solved."),
    },
    puzzle_next = {
        title = _("Next"),
        text = _("Next goes to a new puzzle, chosen close to your puzzle rating, one you have not done yet.\n\nIf you leave a puzzle after a wrong move or a hint, it counts as not solved."),
    },

    -- Famous games
    master_menu = {
        title = _("Game menu"),
        text = _("The game menu holds:\n\n• Choose a game: the famous games on the Kobo\n• Go to the start, Go to the end\n• Move list: every move of the game, with a few words about it\n• Guess White's or Black's moves\n• Flip board"),
    },
    master_back = {
        title = _("Back"),
        text = _("◀ takes back one move, so you can look at the position again."),
    },
    master_forward = {
        title = _("Forward"),
        text = _("▶ plays the next move of the game. The move list under the board shows where you are.\n\nWhile you are guessing, ▶ gives up on the move you are trying to find and shows what the master played."),
    },
    master_guess = {
        title = _("Guess the move"),
        text = _("Guess turns the game into a quiz: at each move of one side (the winner's, unless you choose otherwise in the game menu), play the move you think the master played.\n\n• Right at the first try: 2 points\n• Right at the second try: 1 point\n• Two misses: the master's move is shown\n\nThe other side's moves are played for you. Tap Guess again to stop."),
    },

    -- Openings
    opening_menu = {
        title = _("Opening menu"),
        text = _("The opening menu holds:\n\n• Choose an opening: first the family (Sicilian Defense, Italian Game…), then the line\n• Play as White, Play as Black: the side you learn\n• Next line: the next line of the same family that you have not learned yet\n• Your progress: the lines you have practised and learned"),
    },
    opening_hint = {
        title = _("Hint"),
        text = _("Hint shows the book move: the piece to move is picked up and its square is marked.\n\nA run with a hint does not count towards learning the line."),
    },
    opening_again = {
        title = _("Again"),
        text = _("Again starts the line over from the first move.\n\nA line is learned when you play it three times in a row without a mistake or a hint. Repeat it until it is."),
    },
    opening_flip = {
        title = _("Flip"),
        text = _("Flip turns the board around, so you can see the position from the other side. The side you are learning stays the same."),
    },
}
