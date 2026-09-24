10 REM Catch the falling stars.  A/D or the arrow keys move, ESC quits.
20 CLS: RANDOMIZE: P = 38: S = 0: M = 0
30 X = RND(76) + 2: Y = 2
40 LOCATE 1, 1: COLOR 15: PRINT "Score:"; S; "   Missed:"; M; " of 5 ";: COLOR 7
50 K = INKEY
60 IF (K = 97 OR K = 331) AND P > 4 THEN P = P - 2
70 IF (K = 100 OR K = 333) AND P < 71 THEN P = P + 2
80 LOCATE 24, P - 2: COLOR 11: PRINT "  =====  ";: COLOR 7
90 LOCATE Y, X: PRINT " ";: Y = Y + 1: LOCATE Y, X: COLOR 14: PRINT "*";: COLOR 7
100 PAUSE 100
110 IF Y < 24 THEN 40
120 IF X >= P AND X <= P + 4 THEN S = S + 1: BEEP 880, 30 ELSE M = M + 1: BEEP 150, 100
130 LOCATE Y, X: PRINT " ";
140 IF M < 5 THEN 30
150 LOCATE 1, 1: PRINT "Score:"; S; "   Missed:"; M; " of 5 ": LOCATE 12, 30: COLOR 12: PRINT "GAME OVER - score "; S: COLOR 7
160 LOCATE 23, 1
