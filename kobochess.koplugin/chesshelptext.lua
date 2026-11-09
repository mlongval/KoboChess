--[[--
What each button does: the explanation shown the first time it is
used (chesshelpdialog.lua), until "Do not show this again".

@module kobochess.chesshelptext
--]]

local _ = require("gettext")

return {
    -- The board's own buttons
    close = {
        title = _("X: close Chess"),
        text = _("The X at the top right closes Chess and takes you back to Home.\n\nNothing is lost: the game you are playing is saved after every move, and it is there again, exactly as you left it, the next time you open Chess.\n\nA running clock is paused while Chess is closed."),
    },
    game = {
        title = _("Game menu"),
        text = _("Game ▾ opens the menu for the game you are playing:\n\n• New game: start over, as White, as Black, or two players on one Kobo\n• Start clock / Pause clock (two-player games with a clock)\n• Resign: give up this game\n• Export PGN: save the game as a file\n• Copy FEN: copy the position as one line of text\n\nThe game is saved after every move, so you never lose it by closing Chess or letting the Kobo sleep."),
    },
    undo = {
        title = _("Undo"),
        text = _("Undo takes back the last move. Against the engine it takes back its answer too, so it is your turn again.\n\nTap it as often as you like to go further back. It is a good way to learn: try another move and see what happens.\n\nWith a clock running, the time already used is not given back."),
    },
    hint = {
        title = _("Hint"),
        text = _("Hint asks the engine for a good move for you. It thinks for a few seconds (the status line says \"Looking for a move…\"), then marks the piece to move and the square it goes to.\n\nYou do not have to play it: it is only a suggestion. The hint is always the engine's best try, whatever level you play against."),
    },
    flip = {
        title = _("Flip"),
        text = _("Flip turns the board around, so the other side is at the bottom.\n\nUse it to see the position from your opponent's side, or in a two-player game when the Kobo lies flat between you: the pieces at the top are drawn upside down so the player across the table reads them the right way up.\n\nThe Kobo remembers which way round the board is."),
    },
    refresh = {
        title = _("Refresh"),
        text = _("Refresh flashes the whole screen black and white once.\n\nE-ink keeps faint traces (ghosts) of what was on it before, especially after menus and dialogs. A flash clears them.\n\nTip: hold Refresh (keep your finger on it) to choose how often the board cleans itself without being asked."),
    },
    refresh_interval = {
        title = _("Screen refresh"),
        text = _("This chooses how often the board flashes clean by itself: after every move, every 3, 6 or 12 moves, or never (only when you tap Refresh).\n\nMore often keeps the board crisp; less often is quicker and calmer to look at. The Kobo remembers your choice."),
    },
    options = {
        title = _("Options"),
        text = _("Options ▾ opens the settings for how the game looks and plays:\n\n• Piece set: the drawing of the pieces\n• Engine: the computer opponent\n• Level: how strong it plays\n• Clock: a time limit for two-player games\n• Screen refresh: how often the board flashes clean\n• Show or hide the letters and numbers around the board\n\nEach line shows its current setting. Your choices are kept for next time."),
    },
    clock_tap = {
        title = _("The clocks"),
        text = _("Tapping either clock pauses the game's clocks, and tapping again starts them where they were.\n\nThere is no button to press after a move: making your move switches the clock to the other player by itself. Each player's clock sits at their end of the board, the far one upside down.\n\nWhen a clock reaches zero, that player loses on time."),
    },

    -- Game menu
    new_game = {
        title = _("New game"),
        text = _("New game starts a fresh game. You then choose:\n\n• Play as White: you move first\n• Play as Black: the engine moves first\n• Two players: two people take turns on the same Kobo, no engine\n\nThe game you were playing is replaced. Export it first (Game ▾ > Export PGN) if you want to keep it."),
    },
    play_side = {
        title = _("Your side"),
        text = _("Choose the colour you play against the engine. White always moves first, so with Black the engine starts and you answer.\n\nThe board turns so that your pieces are at the bottom. The engine plays at the level set in Options ▾ > Level."),
    },
    two_players = {
        title = _("Two players"),
        text = _("Two people play each other on the same Kobo, taking turns; the engine stays out of it.\n\nLay the Kobo flat between you: the pieces at the top are drawn upside down for the player across the table. Flip changes which side is at the top.\n\nWant a time limit? Choose one in Options ▾ > Clock: each player then gets a clock at their end of the board."),
    },
    clock_toggle = {
        title = _("Start or pause the clock"),
        text = _("This starts the clocks, or pauses them when they are running, for example when the phone rings.\n\nTapping either clock on the board does the same thing. The clocks only appear in two-player games with a time limit (Options ▾ > Clock)."),
    },
    resign = {
        title = _("Resign"),
        text = _("Resign gives up the game (in a two-player game, the player whose turn it is gives up). You are asked to confirm first, so a slip of the finger does nothing.\n\nAfterwards you can still look at the final position, or start a new game from Game ▾."),
    },
    export_pgn = {
        title = _("Export PGN"),
        text = _("Export PGN saves the game, every move from the start, as a small text file in the Kobo's home folder. A message shows the file's name.\n\nPGN is the usual chess file format: any chess program or website can open it, to replay or study the game on a computer."),
    },
    copy_fen = {
        title = _("Copy FEN"),
        text = _("Copy FEN copies the current position as one line of text (FEN is the usual way to write down a chess position), and shows it on the screen.\n\nYou can paste it into a chess website's analysis board to look at the same position there."),
    },

    -- Options menu
    piece_set = {
        title = _("Piece set"),
        text = _("Piece set chooses how the pieces are drawn. Pick one from the list (the current one has a ✓); the board changes at once.\n\nTry each one to see which is clearest for your eyes on the e-ink screen."),
    },
    engine = {
        title = _("Engine"),
        text = _("The engine is the computer program that plays against you and gives hints.\n\n• Built-in: always there, made for this Kobo\n• Stockfish (when installed): one of the strongest chess programs in the world\n\nPick one from the list; the current one has a ✓. The Level setting makes either one play weaker or stronger."),
    },
    level = {
        title = _("Level"),
        text = _("Level sets how strong the engine plays, from Beginner to Maximum. The time in brackets is how long it may think about each move.\n\nAt the lower levels it also makes human-like mistakes on purpose, so you can win. Start low and go up one step when you win easily.\n\nThe level is kept with the game."),
    },
    time_control = {
        title = _("Clock"),
        text = _("Clock gives each player a time limit, for two-player games. \"5|0\" means 5 minutes each for the whole game; \"15|10\" means 15 minutes, plus 10 seconds added after each move. \"Off\" means no clock.\n\nThe clocks appear at each end of the board. Choosing a clock starts its time over. Against the engine there is no clock: the choice waits for your next two-player game."),
    },
    coordinates = {
        title = _("Coordinates"),
        text = _("This shows or hides the letters (a to h) and numbers (1 to 8) around the board.\n\nEvery square has a name made of its letter and number, such as e4. Books, puzzles and the move list use these names, so having them on the board helps you follow along."),
    },

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
