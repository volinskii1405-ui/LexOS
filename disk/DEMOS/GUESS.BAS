10 REM Guess the number.  In LexOS: hostget guess.bas, then basic guess.bas
20 CLS: COLOR 14: PRINT "=== GUESS THE NUMBER ===": COLOR 7
30 RANDOMIZE
40 N = RND(100): T = 0
50 PRINT "I'm thinking of a number from 1 to 100."
60 INPUT "Your guess"; G
70 T = T + 1
80 IF G < N THEN PRINT "Higher!": BEEP 400, 60: GOTO 60
90 IF G > N THEN PRINT "Lower!": BEEP 300, 60: GOTO 60
100 COLOR 10: PRINT "Right! It was "; N; " - you needed "; T; " tries.": COLOR 7
110 FOR F = 500 TO 1000 STEP 100: BEEP F, 60: NEXT F
120 INPUT "Play again (Y/N)"; A$
130 IF A$ = "Y" OR A$ = "y" THEN 40
140 PRINT "Bye!"
