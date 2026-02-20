" Vim syntax file
" Language: Stele
" Maintainer: Samuel Schlesinger
" Latest Revision: 2026-02-19

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

" Comments
syn match steleComment "--.*$" contains=steleTodo
syn keyword steleTodo contained TODO FIXME XXX NOTE HACK BUG

" Keywords
syn keyword steleKeyword fn do end case match let in
syn keyword steleStructure struct
syn keyword steleTest test

" Built-in I/O
syn keyword steleBuiltin print write readln readint

" Built-in types
syn keyword steleType Int String

" Boolean-like operators as keywords
" (none in stele, but && and || are operators)

" Wildcard pattern
syn match steleWildcard "\<_\>"

" Numbers
syn match steleNumber "\<\d\+\>"

" String literals with escape sequences
syn region steleString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=steleEscape
syn match steleEscape contained "\\[ntr\\\""]"

" Record delimiters
syn match steleRecordDelim "{|"
syn match steleRecordDelim "|}"

" Arrow in case clauses
syn match steleArrow "=>"

" Operators
syn match steleOperator "&&"
syn match steleOperator "||"
syn match steleOperator "=="
syn match steleOperator "!="
syn match steleOperator "<="
syn match steleOperator ">="
syn match steleOperator "[+\-*/%<>]"

" Highlight links
hi def link steleComment Comment
hi def link steleTodo Todo
hi def link steleKeyword Keyword
hi def link steleStructure Structure
hi def link steleTest Keyword
hi def link steleBuiltin Function
hi def link steleType Type
hi def link steleWildcard Special
hi def link steleNumber Number
hi def link steleString String
hi def link steleEscape SpecialChar
hi def link steleRecordDelim Delimiter
hi def link steleArrow Operator
hi def link steleOperator Operator

let b:current_syntax = "stele"

let &cpo = s:cpo_save
unlet s:cpo_save
