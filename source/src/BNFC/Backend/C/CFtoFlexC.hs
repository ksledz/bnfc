{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TupleSections #-}

{-
    BNF Converter: C flex generator
    Copyright (C) 2004  Author:  Michael Pellauer
    Copyright (C) 2020  Andreas Abel

    Description   : This module generates the Flex file. It is
                    similar to JLex but with a few peculiarities.

    Author        : Michael Pellauer
    Created       : 5 August, 2003
-}

module BNFC.Backend.C.CFtoFlexC
  ( cf2flex
  , preludeForBuffer  -- C code defining a buffer for lexing string literals.
  , cMacros           -- Lexer definitions.
  , commentStates     -- Stream of names for lexer states for comments.
  , lexComments       -- Lexing rules for comments.
  , lexStrings        -- Lexing rules for string literals.
  , lexChars          -- Lexing rules for character literals.
  ) where

import Prelude hiding ((<>))
import Data.Bifunctor (first)
import Data.List  (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Map as Map

import BNFC.CF
import BNFC.Backend.C.RegToFlex
import BNFC.Backend.Common.NamedVariables
import BNFC.PrettyPrint
import BNFC.Utils (cstring, unless, when)

-- | Entrypoint.
cf2flex :: String -> CF -> (String, SymMap) -- The environment is reused by the parser.
cf2flex name cf = (, env) $ unlines
    [ prelude stringLiterals name
    , cMacros cf
    , lexSymbols env0
    , restOfFlex cf env
    ]
  where
    env  = Map.fromList env1
    env0 = makeSymEnv (cfgSymbols cf ++ reservedWords cf) [0 :: Int ..]
    env1 = map (first Keyword )env0 ++ makeSymEnv (map Tokentype $ tokenNames cf) [length env0 ..]
    makeSymEnv = zipWith $ \ s n -> (s, "_SYMB_" ++ show n)
    stringLiterals = isUsedCat cf (TokenCat catString)

prelude :: Bool -> String -> String
prelude stringLiterals name = unlines $ concat
  [ [ "/* -*- c -*- This FLex file was machine-generated by the BNF converter */"
    -- noinput and nounput are most often unused
    -- https://stackoverflow.com/questions/39075510/option-noinput-nounput-what-are-they-for
    , "%option noyywrap noinput nounput"
    , "%top{"
    , "/* strdup was not in the ISO C standard before 6/2019 (C2x), but in POSIX 1003.1."
    , " * See: https://en.cppreference.com/w/c/experimental/dynamic/strdup"
    , " * Setting _POSIX_C_SOURCE to 200809L activates strdup in string.h."
    , " */"
    -- The following #define needs to be at the top before the automatic #include <stdlib.h>
    , "#define _POSIX_C_SOURCE 200809L"
    , "}"
    , "%{"
    , "#define yylval " ++ name ++ "lval"
    , "#define yylloc " ++ name ++ "lloc"
    , "#define init_lexer " ++ name ++ "_init_lexer"
    , "#include \"Parser.h\""
    , ""
    ]
  , when stringLiterals $ preludeForBuffer "Buffer.h"
    -- https://www.gnu.org/software/bison/manual/html_node/Token-Locations.html
    -- Flex is responsible for keeping tracking of the yylloc for Bison.
    -- Flex also doesn't do this automatically so we need this function
    -- https://stackoverflow.com/a/22125500/425756
  , [ "static void update_loc(YYLTYPE* loc, char* text)"
    , "{"
    , "  loc->first_line = loc->last_line;"
    , "  loc->first_column = loc->last_column;"
    , "  int i = 0;"  -- put this here as @for (int i...)@ is only allowed in C99
    , "  for (; text[i] != '\\0'; ++i) {"
    , "      if (text[i] == '\\n') {"
    , "          ++loc->last_line;"
    , "          loc->last_column = 0; "
    , "      } else {"
    , "          ++loc->last_column; "
    , "      }"
    , "  }"
    , "}"
    , "#define YY_USER_ACTION update_loc(&yylloc, yytext);"
    , ""
    , "%}"
    ]
  ]

-- | Part of the lexer prelude needed when string literals are to be lexed.
--   Defines an interface to the Buffer.
preludeForBuffer :: String -> [String]
preludeForBuffer bufferH =
    [ "/* BEGIN extensible string buffer */"
    , ""
    , "#include \"" ++ bufferH ++ "\""
    , ""
    , "/* The initial size of the buffer to lex string literals. */"
    , "#define LITERAL_BUFFER_INITIAL_SIZE 1024"
    , ""
    , "/* The pointer to the literal buffer. */"
    , "static Buffer literal_buffer = NULL;"
    , ""
    , "/* Initialize the literal buffer. */"
    , "#define LITERAL_BUFFER_CREATE() literal_buffer = newBuffer(LITERAL_BUFFER_INITIAL_SIZE)"
    , ""
    , "/* Append characters at the end of the buffer. */"
    , "#define LITERAL_BUFFER_APPEND(s) bufferAppendString(literal_buffer, s)"
    , ""
    , "/* Append a character at the end of the buffer. */"
    , "#define LITERAL_BUFFER_APPEND_CHAR(c) bufferAppendChar(literal_buffer, c)"
    , ""
    , "/* Release the buffer, returning a pointer to its content. */"
    , "#define LITERAL_BUFFER_HARVEST() releaseBuffer(literal_buffer)"
    , ""
    , "/* In exceptional cases, e.g. when reaching EOF, we have to free the buffer. */"
    , "#define LITERAL_BUFFER_FREE() freeBuffer(literal_buffer)"
    , ""
    , "/* END extensible string buffer */"
    , ""
    ]

-- For now all categories are included.
-- Optimally only the ones that are used should be generated.
cMacros :: CF ->  String
cMacros cf = unlines
  [ "LETTER [a-zA-Z]"
  , "CAPITAL [A-Z]"
  , "SMALL [a-z]"
  , "DIGIT [0-9]"
  , "IDENT [a-zA-Z0-9'_]"
  , unwords $ concat
      [ [ "%START YYINITIAL CHAR CHARESC CHAREND STRING ESCAPED" ]
      , take (numberOfBlockCommentForms cf) commentStates
      ]
  , ""
  , "%%  /* Rules. */"
  ]

lexSymbols :: KeywordEnv -> String
lexSymbols ss = concatMap transSym ss
  where
    transSym (s,r) =
      "<YYINITIAL>\"" ++ s' ++ "\"      \t return " ++ r ++ ";\n"
        where
         s' = escapeChars s

restOfFlex :: CF -> SymMap -> String
restOfFlex cf env = unlines $ concat
  [ [ render $ lexComments Nothing (comments cf)
    , ""
    ]
  , userDefTokens
  , ifC catString  $ lexStrings "yylval" "_STRING_" "_ERROR_"
  , ifC catChar    $ lexChars   "yylval" "_CHAR_"
  , ifC catDouble  [ "<YYINITIAL>{DIGIT}+\".\"{DIGIT}+(\"e\"(\\-)?{DIGIT}+)?      \t yylval._double = atof(yytext); return _DOUBLE_;" ]
  , ifC catInteger [ "<YYINITIAL>{DIGIT}+      \t yylval._int = atoi(yytext); return _INTEGER_;" ]
  , ifC catIdent   [ "<YYINITIAL>{LETTER}{IDENT}*      \t yylval._string = strdup(yytext); return _IDENT_;" ]
  , [ "<YYINITIAL>[ \\t\\r\\n\\f]      \t /* ignore white space. */;"
    , "<YYINITIAL>.      \t return _ERROR_;"
    , ""
    , "%%  /* Initialization code. */"
    , ""
    ]
  , footer
  ]
  where
  ifC cat s = if isUsedCat cf (TokenCat cat) then s else []
  userDefTokens =
    [ "<YYINITIAL>" ++ printRegFlex exp ++
       "    \t yylval._string = strdup(yytext); return " ++ sName name ++ ";"
    | (name, exp) <- tokenPragmas cf
    ]
    where sName n = fromMaybe n $ Map.lookup (Tokentype n) env
  footer =
    [
     "void init_lexer(FILE *inp)",
     "{",
     "  yyrestart(inp);",
     "  yylloc.first_line   = 1;",
     "  yylloc.first_column = 1;",
     "  yylloc.last_line    = 1;",
     "  yylloc.last_column  = 1;",
     "  BEGIN YYINITIAL;",
     "}"
    ]

-- | Lexing of strings, converting escaped characters.
lexStrings :: String -> String -> String -> [String]
lexStrings yylval stringToken errorToken =
    [ "<YYINITIAL>\"\\\"\"        \t LITERAL_BUFFER_CREATE(); BEGIN STRING;"
    , "<STRING>\\\\             \t BEGIN ESCAPED;"
    , "<STRING>\\\"             \t " ++ yylval ++ "._string = LITERAL_BUFFER_HARVEST(); BEGIN YYINITIAL; return " ++ stringToken ++ ";"
    , "<STRING>.              \t LITERAL_BUFFER_APPEND_CHAR(yytext[0]);"
    , "<ESCAPED>n             \t LITERAL_BUFFER_APPEND_CHAR('\\n'); BEGIN STRING;"
    , "<ESCAPED>\\\"            \t LITERAL_BUFFER_APPEND_CHAR('\"');  BEGIN STRING;"
    , "<ESCAPED>\\\\            \t LITERAL_BUFFER_APPEND_CHAR('\\\\'); BEGIN STRING;"
    , "<ESCAPED>t             \t LITERAL_BUFFER_APPEND_CHAR('\\t'); BEGIN STRING;"
    , "<ESCAPED>.             \t LITERAL_BUFFER_APPEND(yytext);    BEGIN STRING;"
    , "<STRING,ESCAPED><<EOF>>\t LITERAL_BUFFER_FREE(); return " ++ errorToken ++ ";"
    ]

-- | Lexing of characters, converting escaped characters.
lexChars :: String -> String -> [String]
lexChars yylval charToken =
    [ "<YYINITIAL>\"'\" \tBEGIN CHAR;"
    , "<CHAR>\\\\      \t BEGIN CHARESC;"
    , "<CHAR>[^']      \t BEGIN CHAREND; " ++ yylval ++ "._char = yytext[0]; return " ++ charToken ++ ";"
    , "<CHARESC>n      \t BEGIN CHAREND; " ++ yylval ++ "._char = '\\n';     return " ++ charToken ++ ";"
    , "<CHARESC>t      \t BEGIN CHAREND; " ++ yylval ++ "._char = '\\t';     return " ++ charToken ++ ";"
    , "<CHARESC>.      \t BEGIN CHAREND; " ++ yylval ++ "._char = yytext[0]; return " ++ charToken ++ ";"
    , "<CHAREND>\"'\"      \t BEGIN YYINITIAL;"
    ]

-- ---------------------------------------------------------------------------
-- Comments

-- | Create flex rules for single-line and multi-lines comments.
-- The first argument is an optional namespace (for C++); the second
-- argument is the set of comment delimiters as returned by BNFC.CF.comments.
--
-- This function is only compiling the results of applying either
-- lexSingleComment or lexMultiComment on each comment delimiter or pair of
-- delimiters.
--
-- >>> lexComments (Just "myns.") ([("{-","-}")],["--"])
-- <YYINITIAL>"--"[^\n]* /* skip */; /* BNFC: comment "--" */
-- <YYINITIAL>"{-" BEGIN COMMENT; /* BNFC: block comment "{-" "-}" */
-- <COMMENT>"-}" BEGIN YYINITIAL;
-- <COMMENT>.    /* skip */;
-- <COMMENT>[\n] /* skip */;
lexComments :: Maybe String -> ([(String, String)], [String]) -> Doc
lexComments _ (m,s) = vcat $ concat
  [ map    lexSingleComment s
  , zipWith lexMultiComment m commentStates
  ]

-- | If we have several block comments, we need different COMMENT lexing states.
commentStates :: [String]
commentStates = map ("COMMENT" ++) $ "" : map show [1..]

-- | Create a lexer rule for single-line comments.
-- The first argument is -- an optional c++ namespace
-- The second argument is the delimiter that marks the beginning of the
-- comment.
--
-- >>> lexSingleComment "--"
-- <YYINITIAL>"--"[^\n]* /* skip */; /* BNFC: comment "--" */
--
-- >>> lexSingleComment "\""
-- <YYINITIAL>"\""[^\n]* /* skip */; /* BNFC: comment "\"" */
lexSingleComment :: String -> Doc
lexSingleComment c =
    "<YYINITIAL>" <> cstring c <> "[^\\n]*"
    <+> "/* skip */;"
    <+> unless (containsCCommentMarker c) ("/* BNFC: comment" <+> cstring c <+> "*/")

containsCCommentMarker :: String -> Bool
containsCCommentMarker s = "/*" `isInfixOf` s || "*/" `isInfixOf` s

-- | Create a lexer rule for multi-lines comments.
-- The first argument is -- an optional c++ namespace
-- The second arguments is the pair of delimiter for the multi-lines comment:
-- start deleminiter and end delimiter.
-- There might be a possible bug here if a language includes 2 multi-line
-- comments. They could possibly start a comment with one character and end it
-- with another.  However this seems rare.
--
-- >>> lexMultiComment ("{-", "-}") "COMMENT"
-- <YYINITIAL>"{-" BEGIN COMMENT; /* BNFC: block comment "{-" "-}" */
-- <COMMENT>"-}" BEGIN YYINITIAL;
-- <COMMENT>.    /* skip */;
-- <COMMENT>[\n] /* skip */;
--
-- >>> lexMultiComment ("\"'", "'\"") "COMMENT"
-- <YYINITIAL>"\"'" BEGIN COMMENT; /* BNFC: block comment "\"'" "'\"" */
-- <COMMENT>"'\"" BEGIN YYINITIAL;
-- <COMMENT>.    /* skip */;
-- <COMMENT>[\n] /* skip */;
lexMultiComment :: (String, String) -> String -> Doc
lexMultiComment (b,e) comment = vcat
    [ "<YYINITIAL>" <> cstring b <+> "BEGIN" <+> text comment <> ";"
      <+> unless (containsCCommentMarker b || containsCCommentMarker e)
          ("/* BNFC: block comment" <+> cstring b <+> cstring e <+> "*/")
    , commentTag <> cstring e <+> "BEGIN YYINITIAL;"
    , commentTag <> ".    /* skip */;"
    , commentTag <> "[\\n] /* skip */;"
    ]
  where
  commentTag = text $ "<" ++ comment ++ ">"

-- | Helper function that escapes characters in strings.
escapeChars :: String -> String
escapeChars [] = []
escapeChars ('\\':xs) = '\\' : ('\\' : (escapeChars xs))
escapeChars ('\"':xs) = '\\' : ('\"' : (escapeChars xs))
escapeChars (x:xs) = x : (escapeChars xs)
