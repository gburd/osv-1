/* A Bison parser, made by GNU Bison 3.8.2.  */

/* Bison interface for Yacc-like parsers in C

   Copyright (C) 1984, 1989-1990, 2000-2015, 2018-2021 Free Software Foundation,
   Inc.

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.  */

/* As a special exception, you may create a larger work that contains
   part or all of the Bison parser skeleton and distribute that work
   under terms of your choice, so long as that work isn't itself a
   parser generator using the skeleton or a modified version thereof
   as a parser skeleton.  Alternatively, if you modify or redistribute
   the parser skeleton itself, you may (at your option) remove this
   special exception, which will cause the skeleton and the resulting
   Bison output files to be licensed under the GNU General Public
   License without this special exception.

   This special exception was added by the Free Software Foundation in
   version 2.2 of Bison.  */

/* DO NOT RELY ON FEATURES THAT ARE NOT DOCUMENTED in the manual,
   especially those whose name start with YY_ or yy_.  They are
   private implementation details that can be changed or removed.  */

#ifndef YY_BASE_YY_PREPROC_H_INCLUDED
# define YY_BASE_YY_PREPROC_H_INCLUDED
/* Debug traces.  */
#ifndef YYDEBUG
# define YYDEBUG 0
#endif
#if YYDEBUG
extern int base_yydebug;
#endif

/* Token kinds.  */
#ifndef YYTOKENTYPE
# define YYTOKENTYPE
  enum yytokentype
  {
    YYEMPTY = -2,
    YYEOF = 0,                     /* "end of file"  */
    YYerror = 256,                 /* error  */
    YYUNDEF = 257,                 /* "invalid token"  */
    SQL_ALLOCATE = 258,            /* SQL_ALLOCATE  */
    SQL_AUTOCOMMIT = 259,          /* SQL_AUTOCOMMIT  */
    SQL_BOOL = 260,                /* SQL_BOOL  */
    SQL_BREAK = 261,               /* SQL_BREAK  */
    SQL_CARDINALITY = 262,         /* SQL_CARDINALITY  */
    SQL_CONNECT = 263,             /* SQL_CONNECT  */
    SQL_COUNT = 264,               /* SQL_COUNT  */
    SQL_DATETIME_INTERVAL_CODE = 265, /* SQL_DATETIME_INTERVAL_CODE  */
    SQL_DATETIME_INTERVAL_PRECISION = 266, /* SQL_DATETIME_INTERVAL_PRECISION  */
    SQL_DESCRIBE = 267,            /* SQL_DESCRIBE  */
    SQL_DESCRIPTOR = 268,          /* SQL_DESCRIPTOR  */
    SQL_DISCONNECT = 269,          /* SQL_DISCONNECT  */
    SQL_FOUND = 270,               /* SQL_FOUND  */
    SQL_FREE = 271,                /* SQL_FREE  */
    SQL_GET = 272,                 /* SQL_GET  */
    SQL_GO = 273,                  /* SQL_GO  */
    SQL_GOTO = 274,                /* SQL_GOTO  */
    SQL_IDENTIFIED = 275,          /* SQL_IDENTIFIED  */
    SQL_INDICATOR = 276,           /* SQL_INDICATOR  */
    SQL_KEY_MEMBER = 277,          /* SQL_KEY_MEMBER  */
    SQL_LENGTH = 278,              /* SQL_LENGTH  */
    SQL_LONG = 279,                /* SQL_LONG  */
    SQL_NULLABLE = 280,            /* SQL_NULLABLE  */
    SQL_OCTET_LENGTH = 281,        /* SQL_OCTET_LENGTH  */
    SQL_OPEN = 282,                /* SQL_OPEN  */
    SQL_OUTPUT = 283,              /* SQL_OUTPUT  */
    SQL_REFERENCE = 284,           /* SQL_REFERENCE  */
    SQL_RETURNED_LENGTH = 285,     /* SQL_RETURNED_LENGTH  */
    SQL_RETURNED_OCTET_LENGTH = 286, /* SQL_RETURNED_OCTET_LENGTH  */
    SQL_SCALE = 287,               /* SQL_SCALE  */
    SQL_SECTION = 288,             /* SQL_SECTION  */
    SQL_SHORT = 289,               /* SQL_SHORT  */
    SQL_SIGNED = 290,              /* SQL_SIGNED  */
    SQL_SQLERROR = 291,            /* SQL_SQLERROR  */
    SQL_SQLPRINT = 292,            /* SQL_SQLPRINT  */
    SQL_SQLWARNING = 293,          /* SQL_SQLWARNING  */
    SQL_START = 294,               /* SQL_START  */
    SQL_STOP = 295,                /* SQL_STOP  */
    SQL_STRUCT = 296,              /* SQL_STRUCT  */
    SQL_UNSIGNED = 297,            /* SQL_UNSIGNED  */
    SQL_VAR = 298,                 /* SQL_VAR  */
    SQL_WHENEVER = 299,            /* SQL_WHENEVER  */
    S_ADD = 300,                   /* S_ADD  */
    S_AND = 301,                   /* S_AND  */
    S_ANYTHING = 302,              /* S_ANYTHING  */
    S_AUTO = 303,                  /* S_AUTO  */
    S_CONST = 304,                 /* S_CONST  */
    S_DEC = 305,                   /* S_DEC  */
    S_DIV = 306,                   /* S_DIV  */
    S_DOTPOINT = 307,              /* S_DOTPOINT  */
    S_EQUAL = 308,                 /* S_EQUAL  */
    S_EXTERN = 309,                /* S_EXTERN  */
    S_INC = 310,                   /* S_INC  */
    S_LSHIFT = 311,                /* S_LSHIFT  */
    S_MEMPOINT = 312,              /* S_MEMPOINT  */
    S_MEMBER = 313,                /* S_MEMBER  */
    S_MOD = 314,                   /* S_MOD  */
    S_MUL = 315,                   /* S_MUL  */
    S_NEQUAL = 316,                /* S_NEQUAL  */
    S_OR = 317,                    /* S_OR  */
    S_REGISTER = 318,              /* S_REGISTER  */
    S_RSHIFT = 319,                /* S_RSHIFT  */
    S_STATIC = 320,                /* S_STATIC  */
    S_SUB = 321,                   /* S_SUB  */
    S_VOLATILE = 322,              /* S_VOLATILE  */
    S_TYPEDEF = 323,               /* S_TYPEDEF  */
    CSTRING = 324,                 /* CSTRING  */
    CVARIABLE = 325,               /* CVARIABLE  */
    CPP_LINE = 326,                /* CPP_LINE  */
    IP = 327,                      /* IP  */
    IDENT = 328,                   /* IDENT  */
    UIDENT = 329,                  /* UIDENT  */
    FCONST = 330,                  /* FCONST  */
    SCONST = 331,                  /* SCONST  */
    USCONST = 332,                 /* USCONST  */
    BCONST = 333,                  /* BCONST  */
    XCONST = 334,                  /* XCONST  */
    Op = 335,                      /* Op  */
    ICONST = 336,                  /* ICONST  */
    PARAM = 337,                   /* PARAM  */
    TYPECAST = 338,                /* TYPECAST  */
    DOT_DOT = 339,                 /* DOT_DOT  */
    COLON_EQUALS = 340,            /* COLON_EQUALS  */
    EQUALS_GREATER = 341,          /* EQUALS_GREATER  */
    LESS_EQUALS = 342,             /* LESS_EQUALS  */
    GREATER_EQUALS = 343,          /* GREATER_EQUALS  */
    NOT_EQUALS = 344,              /* NOT_EQUALS  */
    ABORT_P = 345,                 /* ABORT_P  */
    ABSENT = 346,                  /* ABSENT  */
    ABSOLUTE_P = 347,              /* ABSOLUTE_P  */
    ACCESS = 348,                  /* ACCESS  */
    ACTION = 349,                  /* ACTION  */
    ADD_P = 350,                   /* ADD_P  */
    ADMIN = 351,                   /* ADMIN  */
    AFTER = 352,                   /* AFTER  */
    AGGREGATE = 353,               /* AGGREGATE  */
    ALL = 354,                     /* ALL  */
    ALSO = 355,                    /* ALSO  */
    ALTER = 356,                   /* ALTER  */
    ALWAYS = 357,                  /* ALWAYS  */
    ANALYSE = 358,                 /* ANALYSE  */
    ANALYZE = 359,                 /* ANALYZE  */
    AND = 360,                     /* AND  */
    ANY = 361,                     /* ANY  */
    ARRAY = 362,                   /* ARRAY  */
    AS = 363,                      /* AS  */
    ASC = 364,                     /* ASC  */
    ASENSITIVE = 365,              /* ASENSITIVE  */
    ASSERTION = 366,               /* ASSERTION  */
    ASSIGNMENT = 367,              /* ASSIGNMENT  */
    ASYMMETRIC = 368,              /* ASYMMETRIC  */
    ATOMIC = 369,                  /* ATOMIC  */
    AT = 370,                      /* AT  */
    ATTACH = 371,                  /* ATTACH  */
    ATTRIBUTE = 372,               /* ATTRIBUTE  */
    AUTHORIZATION = 373,           /* AUTHORIZATION  */
    BACKWARD = 374,                /* BACKWARD  */
    BEFORE = 375,                  /* BEFORE  */
    BEGIN_P = 376,                 /* BEGIN_P  */
    BETWEEN = 377,                 /* BETWEEN  */
    BIGINT = 378,                  /* BIGINT  */
    BINARY = 379,                  /* BINARY  */
    BIT = 380,                     /* BIT  */
    BOOLEAN_P = 381,               /* BOOLEAN_P  */
    BOTH = 382,                    /* BOTH  */
    BREADTH = 383,                 /* BREADTH  */
    BY = 384,                      /* BY  */
    CACHE = 385,                   /* CACHE  */
    CALL = 386,                    /* CALL  */
    CALLED = 387,                  /* CALLED  */
    CASCADE = 388,                 /* CASCADE  */
    CASCADED = 389,                /* CASCADED  */
    CASE = 390,                    /* CASE  */
    CAST = 391,                    /* CAST  */
    CATALOG_P = 392,               /* CATALOG_P  */
    CHAIN = 393,                   /* CHAIN  */
    CHAR_P = 394,                  /* CHAR_P  */
    CHARACTER = 395,               /* CHARACTER  */
    CHARACTERISTICS = 396,         /* CHARACTERISTICS  */
    CHECK = 397,                   /* CHECK  */
    CHECKPOINT = 398,              /* CHECKPOINT  */
    CLASS = 399,                   /* CLASS  */
    CLOSE = 400,                   /* CLOSE  */
    CLUSTER = 401,                 /* CLUSTER  */
    COALESCE = 402,                /* COALESCE  */
    COLLATE = 403,                 /* COLLATE  */
    COLLATION = 404,               /* COLLATION  */
    COLUMN = 405,                  /* COLUMN  */
    COLUMNS = 406,                 /* COLUMNS  */
    COMMENT = 407,                 /* COMMENT  */
    COMMENTS = 408,                /* COMMENTS  */
    COMMIT = 409,                  /* COMMIT  */
    COMMITTED = 410,               /* COMMITTED  */
    COMPRESSION = 411,             /* COMPRESSION  */
    CONCURRENTLY = 412,            /* CONCURRENTLY  */
    CONDITIONAL = 413,             /* CONDITIONAL  */
    CONFIGURATION = 414,           /* CONFIGURATION  */
    CONFLICT = 415,                /* CONFLICT  */
    CONNECTION = 416,              /* CONNECTION  */
    CONSTRAINT = 417,              /* CONSTRAINT  */
    CONSTRAINTS = 418,             /* CONSTRAINTS  */
    CONTENT_P = 419,               /* CONTENT_P  */
    CONTINUE_P = 420,              /* CONTINUE_P  */
    CONVERSION_P = 421,            /* CONVERSION_P  */
    COPY = 422,                    /* COPY  */
    COST = 423,                    /* COST  */
    CREATE = 424,                  /* CREATE  */
    CROSS = 425,                   /* CROSS  */
    CSV = 426,                     /* CSV  */
    CUBE = 427,                    /* CUBE  */
    CURRENT_P = 428,               /* CURRENT_P  */
    CURRENT_CATALOG = 429,         /* CURRENT_CATALOG  */
    CURRENT_DATE = 430,            /* CURRENT_DATE  */
    CURRENT_ROLE = 431,            /* CURRENT_ROLE  */
    CURRENT_SCHEMA = 432,          /* CURRENT_SCHEMA  */
    CURRENT_TIME = 433,            /* CURRENT_TIME  */
    CURRENT_TIMESTAMP = 434,       /* CURRENT_TIMESTAMP  */
    CURRENT_USER = 435,            /* CURRENT_USER  */
    CURSOR = 436,                  /* CURSOR  */
    CYCLE = 437,                   /* CYCLE  */
    DATA_P = 438,                  /* DATA_P  */
    DATABASE = 439,                /* DATABASE  */
    DAY_P = 440,                   /* DAY_P  */
    DEALLOCATE = 441,              /* DEALLOCATE  */
    DEC = 442,                     /* DEC  */
    DECIMAL_P = 443,               /* DECIMAL_P  */
    DECLARE = 444,                 /* DECLARE  */
    DEFAULT = 445,                 /* DEFAULT  */
    DEFAULTS = 446,                /* DEFAULTS  */
    DEFERRABLE = 447,              /* DEFERRABLE  */
    DEFERRED = 448,                /* DEFERRED  */
    DEFINER = 449,                 /* DEFINER  */
    DELETE_P = 450,                /* DELETE_P  */
    DELIMITER = 451,               /* DELIMITER  */
    DELIMITERS = 452,              /* DELIMITERS  */
    DEPENDS = 453,                 /* DEPENDS  */
    DEPTH = 454,                   /* DEPTH  */
    DESC = 455,                    /* DESC  */
    DETACH = 456,                  /* DETACH  */
    DICTIONARY = 457,              /* DICTIONARY  */
    DISABLE_P = 458,               /* DISABLE_P  */
    DISCARD = 459,                 /* DISCARD  */
    DISTINCT = 460,                /* DISTINCT  */
    DO = 461,                      /* DO  */
    DOCUMENT_P = 462,              /* DOCUMENT_P  */
    DOMAIN_P = 463,                /* DOMAIN_P  */
    DOUBLE_P = 464,                /* DOUBLE_P  */
    DROP = 465,                    /* DROP  */
    EACH = 466,                    /* EACH  */
    ELSE = 467,                    /* ELSE  */
    EMPTY_P = 468,                 /* EMPTY_P  */
    ENABLE_P = 469,                /* ENABLE_P  */
    ENCODING = 470,                /* ENCODING  */
    ENCRYPTED = 471,               /* ENCRYPTED  */
    END_P = 472,                   /* END_P  */
    ENFORCED = 473,                /* ENFORCED  */
    ENUM_P = 474,                  /* ENUM_P  */
    ERROR_P = 475,                 /* ERROR_P  */
    ESCAPE = 476,                  /* ESCAPE  */
    EVENT = 477,                   /* EVENT  */
    EXCEPT = 478,                  /* EXCEPT  */
    EXCLUDE = 479,                 /* EXCLUDE  */
    EXCLUDING = 480,               /* EXCLUDING  */
    EXCLUSIVE = 481,               /* EXCLUSIVE  */
    EXECUTE = 482,                 /* EXECUTE  */
    EXISTS = 483,                  /* EXISTS  */
    EXPLAIN = 484,                 /* EXPLAIN  */
    EXPRESSION = 485,              /* EXPRESSION  */
    EXTENSION = 486,               /* EXTENSION  */
    EXTERNAL = 487,                /* EXTERNAL  */
    EXTRACT = 488,                 /* EXTRACT  */
    FALSE_P = 489,                 /* FALSE_P  */
    FAMILY = 490,                  /* FAMILY  */
    FETCH = 491,                   /* FETCH  */
    FILTER = 492,                  /* FILTER  */
    FINALIZE = 493,                /* FINALIZE  */
    FIRST_P = 494,                 /* FIRST_P  */
    FLOAT_P = 495,                 /* FLOAT_P  */
    FOLLOWING = 496,               /* FOLLOWING  */
    FOR = 497,                     /* FOR  */
    FORCE = 498,                   /* FORCE  */
    FOREIGN = 499,                 /* FOREIGN  */
    FORMAT = 500,                  /* FORMAT  */
    FORWARD = 501,                 /* FORWARD  */
    FREEZE = 502,                  /* FREEZE  */
    FROM = 503,                    /* FROM  */
    FULL = 504,                    /* FULL  */
    FUNCTION = 505,                /* FUNCTION  */
    FUNCTIONS = 506,               /* FUNCTIONS  */
    GENERATED = 507,               /* GENERATED  */
    GLOBAL = 508,                  /* GLOBAL  */
    GRANT = 509,                   /* GRANT  */
    GRANTED = 510,                 /* GRANTED  */
    GREATEST = 511,                /* GREATEST  */
    GROUP_P = 512,                 /* GROUP_P  */
    GROUPING = 513,                /* GROUPING  */
    GROUPS = 514,                  /* GROUPS  */
    HANDLER = 515,                 /* HANDLER  */
    HAVING = 516,                  /* HAVING  */
    HEADER_P = 517,                /* HEADER_P  */
    HOLD = 518,                    /* HOLD  */
    HOUR_P = 519,                  /* HOUR_P  */
    IDENTITY_P = 520,              /* IDENTITY_P  */
    IF_P = 521,                    /* IF_P  */
    ILIKE = 522,                   /* ILIKE  */
    IMMEDIATE = 523,               /* IMMEDIATE  */
    IMMUTABLE = 524,               /* IMMUTABLE  */
    IMPLICIT_P = 525,              /* IMPLICIT_P  */
    IMPORT_P = 526,                /* IMPORT_P  */
    IN_P = 527,                    /* IN_P  */
    INCLUDE = 528,                 /* INCLUDE  */
    INCLUDING = 529,               /* INCLUDING  */
    INCREMENT = 530,               /* INCREMENT  */
    INDENT = 531,                  /* INDENT  */
    INDEX = 532,                   /* INDEX  */
    INDEXES = 533,                 /* INDEXES  */
    INHERIT = 534,                 /* INHERIT  */
    INHERITS = 535,                /* INHERITS  */
    INITIALLY = 536,               /* INITIALLY  */
    INLINE_P = 537,                /* INLINE_P  */
    INNER_P = 538,                 /* INNER_P  */
    INOUT = 539,                   /* INOUT  */
    INPUT_P = 540,                 /* INPUT_P  */
    INSENSITIVE = 541,             /* INSENSITIVE  */
    INSERT = 542,                  /* INSERT  */
    INSTEAD = 543,                 /* INSTEAD  */
    INT_P = 544,                   /* INT_P  */
    INTEGER = 545,                 /* INTEGER  */
    INTERSECT = 546,               /* INTERSECT  */
    INTERVAL = 547,                /* INTERVAL  */
    INTO = 548,                    /* INTO  */
    INVOKER = 549,                 /* INVOKER  */
    IS = 550,                      /* IS  */
    ISNULL = 551,                  /* ISNULL  */
    ISOLATION = 552,               /* ISOLATION  */
    JOIN = 553,                    /* JOIN  */
    JSON = 554,                    /* JSON  */
    JSON_ARRAY = 555,              /* JSON_ARRAY  */
    JSON_ARRAYAGG = 556,           /* JSON_ARRAYAGG  */
    JSON_EXISTS = 557,             /* JSON_EXISTS  */
    JSON_OBJECT = 558,             /* JSON_OBJECT  */
    JSON_OBJECTAGG = 559,          /* JSON_OBJECTAGG  */
    JSON_QUERY = 560,              /* JSON_QUERY  */
    JSON_SCALAR = 561,             /* JSON_SCALAR  */
    JSON_SERIALIZE = 562,          /* JSON_SERIALIZE  */
    JSON_TABLE = 563,              /* JSON_TABLE  */
    JSON_VALUE = 564,              /* JSON_VALUE  */
    KEEP = 565,                    /* KEEP  */
    KEY = 566,                     /* KEY  */
    KEYS = 567,                    /* KEYS  */
    LABEL = 568,                   /* LABEL  */
    LANGUAGE = 569,                /* LANGUAGE  */
    LARGE_P = 570,                 /* LARGE_P  */
    LAST_P = 571,                  /* LAST_P  */
    LATERAL_P = 572,               /* LATERAL_P  */
    LEADING = 573,                 /* LEADING  */
    LEAKPROOF = 574,               /* LEAKPROOF  */
    LEAST = 575,                   /* LEAST  */
    LEFT = 576,                    /* LEFT  */
    LEVEL = 577,                   /* LEVEL  */
    LIKE = 578,                    /* LIKE  */
    LIMIT = 579,                   /* LIMIT  */
    LISTEN = 580,                  /* LISTEN  */
    LOAD = 581,                    /* LOAD  */
    LOCAL = 582,                   /* LOCAL  */
    LOCALTIME = 583,               /* LOCALTIME  */
    LOCALTIMESTAMP = 584,          /* LOCALTIMESTAMP  */
    LOCATION = 585,                /* LOCATION  */
    LOCK_P = 586,                  /* LOCK_P  */
    LOCKED = 587,                  /* LOCKED  */
    LOGGED = 588,                  /* LOGGED  */
    MAPPING = 589,                 /* MAPPING  */
    MATCH = 590,                   /* MATCH  */
    MATCHED = 591,                 /* MATCHED  */
    MATERIALIZED = 592,            /* MATERIALIZED  */
    MAXVALUE = 593,                /* MAXVALUE  */
    MERGE = 594,                   /* MERGE  */
    MERGE_ACTION = 595,            /* MERGE_ACTION  */
    METHOD = 596,                  /* METHOD  */
    MINUTE_P = 597,                /* MINUTE_P  */
    MINVALUE = 598,                /* MINVALUE  */
    MODE = 599,                    /* MODE  */
    MONTH_P = 600,                 /* MONTH_P  */
    MOVE = 601,                    /* MOVE  */
    NAME_P = 602,                  /* NAME_P  */
    NAMES = 603,                   /* NAMES  */
    NATIONAL = 604,                /* NATIONAL  */
    NATURAL = 605,                 /* NATURAL  */
    NCHAR = 606,                   /* NCHAR  */
    NESTED = 607,                  /* NESTED  */
    NEW = 608,                     /* NEW  */
    NEXT = 609,                    /* NEXT  */
    NFC = 610,                     /* NFC  */
    NFD = 611,                     /* NFD  */
    NFKC = 612,                    /* NFKC  */
    NFKD = 613,                    /* NFKD  */
    NO = 614,                      /* NO  */
    NONE = 615,                    /* NONE  */
    NORMALIZE = 616,               /* NORMALIZE  */
    NORMALIZED = 617,              /* NORMALIZED  */
    NOT = 618,                     /* NOT  */
    NOTHING = 619,                 /* NOTHING  */
    NOTIFY = 620,                  /* NOTIFY  */
    NOTNULL = 621,                 /* NOTNULL  */
    NOWAIT = 622,                  /* NOWAIT  */
    NULL_P = 623,                  /* NULL_P  */
    NULLIF = 624,                  /* NULLIF  */
    NULLS_P = 625,                 /* NULLS_P  */
    NUMERIC = 626,                 /* NUMERIC  */
    OBJECT_P = 627,                /* OBJECT_P  */
    OBJECTS_P = 628,               /* OBJECTS_P  */
    OF = 629,                      /* OF  */
    OFF = 630,                     /* OFF  */
    OFFSET = 631,                  /* OFFSET  */
    OIDS = 632,                    /* OIDS  */
    OLD = 633,                     /* OLD  */
    OMIT = 634,                    /* OMIT  */
    ON = 635,                      /* ON  */
    ONLY = 636,                    /* ONLY  */
    OPERATOR = 637,                /* OPERATOR  */
    OPTION = 638,                  /* OPTION  */
    OPTIONS = 639,                 /* OPTIONS  */
    OR = 640,                      /* OR  */
    ORDER = 641,                   /* ORDER  */
    ORDINALITY = 642,              /* ORDINALITY  */
    OTHERS = 643,                  /* OTHERS  */
    OUT_P = 644,                   /* OUT_P  */
    OUTER_P = 645,                 /* OUTER_P  */
    OVER = 646,                    /* OVER  */
    OVERLAPS = 647,                /* OVERLAPS  */
    OVERLAY = 648,                 /* OVERLAY  */
    OVERRIDING = 649,              /* OVERRIDING  */
    OWNED = 650,                   /* OWNED  */
    OWNER = 651,                   /* OWNER  */
    PARALLEL = 652,                /* PARALLEL  */
    PARAMETER = 653,               /* PARAMETER  */
    PARSER = 654,                  /* PARSER  */
    PARTIAL = 655,                 /* PARTIAL  */
    PARTITION = 656,               /* PARTITION  */
    PASSING = 657,                 /* PASSING  */
    PASSWORD = 658,                /* PASSWORD  */
    PATH = 659,                    /* PATH  */
    PERIOD = 660,                  /* PERIOD  */
    PLACING = 661,                 /* PLACING  */
    PLAN = 662,                    /* PLAN  */
    PLANS = 663,                   /* PLANS  */
    POLICY = 664,                  /* POLICY  */
    POSITION = 665,                /* POSITION  */
    PRECEDING = 666,               /* PRECEDING  */
    PRECISION = 667,               /* PRECISION  */
    PRESERVE = 668,                /* PRESERVE  */
    PREPARE = 669,                 /* PREPARE  */
    PREPARED = 670,                /* PREPARED  */
    PRIMARY = 671,                 /* PRIMARY  */
    PRIOR = 672,                   /* PRIOR  */
    PRIVILEGES = 673,              /* PRIVILEGES  */
    PROCEDURAL = 674,              /* PROCEDURAL  */
    PROCEDURE = 675,               /* PROCEDURE  */
    PROCEDURES = 676,              /* PROCEDURES  */
    PROGRAM = 677,                 /* PROGRAM  */
    PUBLICATION = 678,             /* PUBLICATION  */
    QUOTE = 679,                   /* QUOTE  */
    QUOTES = 680,                  /* QUOTES  */
    RANGE = 681,                   /* RANGE  */
    READ = 682,                    /* READ  */
    REAL = 683,                    /* REAL  */
    REASSIGN = 684,                /* REASSIGN  */
    RECURSIVE = 685,               /* RECURSIVE  */
    REF_P = 686,                   /* REF_P  */
    REFERENCES = 687,              /* REFERENCES  */
    REFERENCING = 688,             /* REFERENCING  */
    REFRESH = 689,                 /* REFRESH  */
    REINDEX = 690,                 /* REINDEX  */
    RELATIVE_P = 691,              /* RELATIVE_P  */
    RELEASE = 692,                 /* RELEASE  */
    RENAME = 693,                  /* RENAME  */
    REPEATABLE = 694,              /* REPEATABLE  */
    REPLACE = 695,                 /* REPLACE  */
    REPLICA = 696,                 /* REPLICA  */
    RESET = 697,                   /* RESET  */
    RESTART = 698,                 /* RESTART  */
    RESTRICT = 699,                /* RESTRICT  */
    RETURN = 700,                  /* RETURN  */
    RETURNING = 701,               /* RETURNING  */
    RETURNS = 702,                 /* RETURNS  */
    REVOKE = 703,                  /* REVOKE  */
    RIGHT = 704,                   /* RIGHT  */
    ROLE = 705,                    /* ROLE  */
    ROLLBACK = 706,                /* ROLLBACK  */
    ROLLUP = 707,                  /* ROLLUP  */
    ROUTINE = 708,                 /* ROUTINE  */
    ROUTINES = 709,                /* ROUTINES  */
    ROW = 710,                     /* ROW  */
    ROWS = 711,                    /* ROWS  */
    RULE = 712,                    /* RULE  */
    SAVEPOINT = 713,               /* SAVEPOINT  */
    SCALAR = 714,                  /* SCALAR  */
    SCHEMA = 715,                  /* SCHEMA  */
    SCHEMAS = 716,                 /* SCHEMAS  */
    SCROLL = 717,                  /* SCROLL  */
    SEARCH = 718,                  /* SEARCH  */
    SECOND_P = 719,                /* SECOND_P  */
    SECURITY = 720,                /* SECURITY  */
    SELECT = 721,                  /* SELECT  */
    SEQUENCE = 722,                /* SEQUENCE  */
    SEQUENCES = 723,               /* SEQUENCES  */
    SERIALIZABLE = 724,            /* SERIALIZABLE  */
    SERVER = 725,                  /* SERVER  */
    SESSION = 726,                 /* SESSION  */
    SESSION_USER = 727,            /* SESSION_USER  */
    SET = 728,                     /* SET  */
    SETS = 729,                    /* SETS  */
    SETOF = 730,                   /* SETOF  */
    SHARE = 731,                   /* SHARE  */
    SHOW = 732,                    /* SHOW  */
    SIMILAR = 733,                 /* SIMILAR  */
    SIMPLE = 734,                  /* SIMPLE  */
    SKIP = 735,                    /* SKIP  */
    SMALLINT = 736,                /* SMALLINT  */
    SNAPSHOT = 737,                /* SNAPSHOT  */
    SOME = 738,                    /* SOME  */
    SOURCE = 739,                  /* SOURCE  */
    SQL_P = 740,                   /* SQL_P  */
    STABLE = 741,                  /* STABLE  */
    STANDALONE_P = 742,            /* STANDALONE_P  */
    START = 743,                   /* START  */
    STATEMENT = 744,               /* STATEMENT  */
    STATISTICS = 745,              /* STATISTICS  */
    STDIN = 746,                   /* STDIN  */
    STDOUT = 747,                  /* STDOUT  */
    STORAGE = 748,                 /* STORAGE  */
    STORED = 749,                  /* STORED  */
    STRICT_P = 750,                /* STRICT_P  */
    STRING_P = 751,                /* STRING_P  */
    STRIP_P = 752,                 /* STRIP_P  */
    SUBSCRIPTION = 753,            /* SUBSCRIPTION  */
    SUBSTRING = 754,               /* SUBSTRING  */
    SUPPORT = 755,                 /* SUPPORT  */
    SYMMETRIC = 756,               /* SYMMETRIC  */
    SYSID = 757,                   /* SYSID  */
    SYSTEM_P = 758,                /* SYSTEM_P  */
    SYSTEM_USER = 759,             /* SYSTEM_USER  */
    TABLE = 760,                   /* TABLE  */
    TABLES = 761,                  /* TABLES  */
    TABLESAMPLE = 762,             /* TABLESAMPLE  */
    TABLESPACE = 763,              /* TABLESPACE  */
    TARGET = 764,                  /* TARGET  */
    TEMP = 765,                    /* TEMP  */
    TEMPLATE = 766,                /* TEMPLATE  */
    TEMPORARY = 767,               /* TEMPORARY  */
    TEXT_P = 768,                  /* TEXT_P  */
    THEN = 769,                    /* THEN  */
    TIES = 770,                    /* TIES  */
    TIME = 771,                    /* TIME  */
    TIMESTAMP = 772,               /* TIMESTAMP  */
    TO = 773,                      /* TO  */
    TRAILING = 774,                /* TRAILING  */
    TRANSACTION = 775,             /* TRANSACTION  */
    TRANSFORM = 776,               /* TRANSFORM  */
    TREAT = 777,                   /* TREAT  */
    TRIGGER = 778,                 /* TRIGGER  */
    TRIM = 779,                    /* TRIM  */
    TRUE_P = 780,                  /* TRUE_P  */
    TRUNCATE = 781,                /* TRUNCATE  */
    TRUSTED = 782,                 /* TRUSTED  */
    TYPE_P = 783,                  /* TYPE_P  */
    TYPES_P = 784,                 /* TYPES_P  */
    UESCAPE = 785,                 /* UESCAPE  */
    UNBOUNDED = 786,               /* UNBOUNDED  */
    UNCONDITIONAL = 787,           /* UNCONDITIONAL  */
    UNCOMMITTED = 788,             /* UNCOMMITTED  */
    UNENCRYPTED = 789,             /* UNENCRYPTED  */
    UNION = 790,                   /* UNION  */
    UNIQUE = 791,                  /* UNIQUE  */
    UNKNOWN = 792,                 /* UNKNOWN  */
    UNLISTEN = 793,                /* UNLISTEN  */
    UNLOGGED = 794,                /* UNLOGGED  */
    UNTIL = 795,                   /* UNTIL  */
    UPDATE = 796,                  /* UPDATE  */
    USER = 797,                    /* USER  */
    USING = 798,                   /* USING  */
    VACUUM = 799,                  /* VACUUM  */
    VALID = 800,                   /* VALID  */
    VALIDATE = 801,                /* VALIDATE  */
    VALIDATOR = 802,               /* VALIDATOR  */
    VALUE_P = 803,                 /* VALUE_P  */
    VALUES = 804,                  /* VALUES  */
    VARCHAR = 805,                 /* VARCHAR  */
    VARIADIC = 806,                /* VARIADIC  */
    VARYING = 807,                 /* VARYING  */
    VERBOSE = 808,                 /* VERBOSE  */
    VERSION_P = 809,               /* VERSION_P  */
    VIEW = 810,                    /* VIEW  */
    VIEWS = 811,                   /* VIEWS  */
    VIRTUAL = 812,                 /* VIRTUAL  */
    VOLATILE = 813,                /* VOLATILE  */
    WHEN = 814,                    /* WHEN  */
    WHERE = 815,                   /* WHERE  */
    WHITESPACE_P = 816,            /* WHITESPACE_P  */
    WINDOW = 817,                  /* WINDOW  */
    WITH = 818,                    /* WITH  */
    WITHIN = 819,                  /* WITHIN  */
    WITHOUT = 820,                 /* WITHOUT  */
    WORK = 821,                    /* WORK  */
    WRAPPER = 822,                 /* WRAPPER  */
    WRITE = 823,                   /* WRITE  */
    XML_P = 824,                   /* XML_P  */
    XMLATTRIBUTES = 825,           /* XMLATTRIBUTES  */
    XMLCONCAT = 826,               /* XMLCONCAT  */
    XMLELEMENT = 827,              /* XMLELEMENT  */
    XMLEXISTS = 828,               /* XMLEXISTS  */
    XMLFOREST = 829,               /* XMLFOREST  */
    XMLNAMESPACES = 830,           /* XMLNAMESPACES  */
    XMLPARSE = 831,                /* XMLPARSE  */
    XMLPI = 832,                   /* XMLPI  */
    XMLROOT = 833,                 /* XMLROOT  */
    XMLSERIALIZE = 834,            /* XMLSERIALIZE  */
    XMLTABLE = 835,                /* XMLTABLE  */
    YEAR_P = 836,                  /* YEAR_P  */
    YES_P = 837,                   /* YES_P  */
    ZONE = 838,                    /* ZONE  */
    FORMAT_LA = 839,               /* FORMAT_LA  */
    NOT_LA = 840,                  /* NOT_LA  */
    NULLS_LA = 841,                /* NULLS_LA  */
    WITH_LA = 842,                 /* WITH_LA  */
    WITHOUT_LA = 843,              /* WITHOUT_LA  */
    MODE_TYPE_NAME = 844,          /* MODE_TYPE_NAME  */
    MODE_PLPGSQL_EXPR = 845,       /* MODE_PLPGSQL_EXPR  */
    MODE_PLPGSQL_ASSIGN1 = 846,    /* MODE_PLPGSQL_ASSIGN1  */
    MODE_PLPGSQL_ASSIGN2 = 847,    /* MODE_PLPGSQL_ASSIGN2  */
    MODE_PLPGSQL_ASSIGN3 = 848,    /* MODE_PLPGSQL_ASSIGN3  */
    UMINUS = 849                   /* UMINUS  */
  };
  typedef enum yytokentype yytoken_kind_t;
#endif

/* Value type.  */
#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
union YYSTYPE
{
#line 589 "preproc.y"

	double		dval;
	char	   *str;
	int			ival;
	struct when action;
	struct index index;
	int			tagname;
	struct this_type type;
	enum ECPGttype type_enum;
	enum ECPGdtype dtype_enum;
	struct fetch_desc descriptor;
	struct su_symbol struct_union;
	struct prep prep;
	struct exec exec;
	struct describe describe;

#line 675 "preproc.h"

};
typedef union YYSTYPE YYSTYPE;
# define YYSTYPE_IS_TRIVIAL 1
# define YYSTYPE_IS_DECLARED 1
#endif

/* Location type.  */
#if ! defined YYLTYPE && ! defined YYLTYPE_IS_DECLARED
typedef struct YYLTYPE YYLTYPE;
struct YYLTYPE
{
  int first_line;
  int first_column;
  int last_line;
  int last_column;
};
# define YYLTYPE_IS_DECLARED 1
# define YYLTYPE_IS_TRIVIAL 1
#endif


extern YYSTYPE base_yylval;
extern YYLTYPE base_yylloc;

int base_yyparse (void);


#endif /* !YY_BASE_YY_PREPROC_H_INCLUDED  */
