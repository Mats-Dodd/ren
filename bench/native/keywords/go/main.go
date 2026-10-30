// The keyword kernel's Go twin (bench/native/keywords, gen.py): each
// set a `switch`. `main <set> <n> <rounds>`.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func renkw(s string) int64 {
	switch s {
	case "fn":
		return 0
	case "pub":
		return 1
	case "let":
		return 2
	case "var":
		return 3
	case "inout":
		return 4
	case "for":
		return 5
	case "while":
		return 6
	case "break":
		return 7
	case "todo":
		return 8
	case "in":
		return 9
	case "if":
		return 10
	case "then":
		return 11
	case "else":
		return 12
	case "true":
		return 13
	case "false":
		return 14
	case "type":
		return 15
	case "dep":
		return 16
	case "match":
		return 17
	case "import":
		return 18
	case "as":
		return 19
	case "uses":
		return 20
	case "opaque":
		return 21
	case "self":
		return 22
	case "not":
		return 23
	case "fail":
		return 24
	case "try":
		return 25
	case "attempt":
		return 26
	case "orelse":
		return 27
	case "with":
		return 28
	case "handler":
		return 29
	case "over":
		return 30
	case "finally":
		return 31
	case "test":
		return 32
	case "group":
		return 33
	case "assert":
		return 34
	}
	return -1
}

func jsreserved(s string) int64 {
	switch s {
	case "await":
		return 0
	case "break":
		return 1
	case "case":
		return 2
	case "catch":
		return 3
	case "class":
		return 4
	case "const":
		return 5
	case "continue":
		return 6
	case "debugger":
		return 7
	case "default":
		return 8
	case "delete":
		return 9
	case "do":
		return 10
	case "else":
		return 11
	case "enum":
		return 12
	case "export":
		return 13
	case "extends":
		return 14
	case "false":
		return 15
	case "finally":
		return 16
	case "for":
		return 17
	case "function":
		return 18
	case "if":
		return 19
	case "import":
		return 20
	case "in":
		return 21
	case "instanceof":
		return 22
	case "new":
		return 23
	case "null":
		return 24
	case "return":
		return 25
	case "super":
		return 26
	case "switch":
		return 27
	case "this":
		return 28
	case "throw":
		return 29
	case "true":
		return 30
	case "try":
		return 31
	case "typeof":
		return 32
	case "var":
		return 33
	case "void":
		return 34
	case "while":
		return 35
	case "with":
		return 36
	case "yield":
		return 37
	case "implements":
		return 38
	case "interface":
		return 39
	case "package":
		return 40
	case "private":
		return 41
	case "protected":
		return 42
	case "public":
		return 43
	case "static":
		return 44
	}
	return -1
}

func methods(s string) int64 {
	switch s {
	case "GET":
		return 0
	case "HEAD":
		return 1
	case "POST":
		return 2
	case "PUT":
		return 3
	case "DELETE":
		return 4
	case "CONNECT":
		return 5
	case "OPTIONS":
		return 6
	case "TRACE":
		return 7
	case "PATCH":
		return 8
	}
	return -1
}

func headers(s string) int64 {
	switch s {
	case "Accept":
		return 0
	case "Accept-Encoding":
		return 1
	case "Authorization":
		return 2
	case "Cache-Control":
		return 3
	case "Connection":
		return 4
	case "Content-Length":
		return 5
	case "Content-Type":
		return 6
	case "Cookie":
		return 7
	case "Date":
		return 8
	case "Host":
		return 9
	case "If-None-Match":
		return 10
	case "Location":
		return 11
	case "Origin":
		return 12
	case "Referer":
		return 13
	case "Server":
		return 14
	case "Set-Cookie":
		return 15
	case "User-Agent":
		return 16
	case "Vary":
		return 17
	case "Via":
		return 18
	case "X-Forwarded-For":
		return 19
	}
	return -1
}

func json24(s string) int64 {
	switch s {
	case "id":
		return 0
	case "name":
		return 1
	case "email":
		return 2
	case "created_at":
		return 3
	case "updated_at":
		return 4
	case "deleted_at":
		return 5
	case "status":
		return 6
	case "owner_id":
		return 7
	case "org_id":
		return 8
	case "tags":
		return 9
	case "title":
		return 10
	case "description":
		return 11
	case "priority":
		return 12
	case "due_date":
		return 13
	case "assignee_id":
		return 14
	case "labels":
		return 15
	case "version":
		return 16
	case "etag":
		return 17
	case "parent_id":
		return 18
	case "metadata":
		return 19
	case "visibility":
		return 20
	case "archived":
		return 21
	case "last_modified_by":
		return 22
	case "notification_settings":
		return 23
	}
	return -1
}

func one(s string) int64 {
	switch s {
	case "v1":
		return 0
	}
	return -1
}

func keys(set string) []string {
	switch set {
	case "renkw":
		return []string{"fn", "pub", "let", "var", "inout", "for", "while", "break", "todo", "in", "if", "then", "else", "true", "false", "type", "dep", "match", "import", "as", "uses", "opaque", "self", "not", "fail", "try", "attempt", "orelse", "with", "handler", "over", "finally", "test", "group", "assert"}
	case "jsreserved":
		return []string{"await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "implements", "interface", "package", "private", "protected", "public", "static"}
	case "methods":
		return []string{"GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"}
	case "headers":
		return []string{"Accept", "Accept-Encoding", "Authorization", "Cache-Control", "Connection", "Content-Length", "Content-Type", "Cookie", "Date", "Host", "If-None-Match", "Location", "Origin", "Referer", "Server", "Set-Cookie", "User-Agent", "Vary", "Via", "X-Forwarded-For"}
	case "json24":
		return []string{"id", "name", "email", "created_at", "updated_at", "deleted_at", "status", "owner_id", "org_id", "tags", "title", "description", "priority", "due_date", "assignee_id", "labels", "version", "etag", "parent_id", "metadata", "visibility", "archived", "last_modified_by", "notification_settings"}
	case "one":
		return []string{"v1"}
	}
	return nil
}

func next(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func queries(keys []string, n int) []string {
	qs := make([]string, 0, n)
	var x int64 = 42
	for i := 0; i < n; i++ {
		x = next(x)
		k := keys[x%int64(len(keys))]
		x = next(x)
		if x%10 != 0 {
			qs = append(qs, k)
		} else if x/10%2 == 0 {
			qs = append(qs, k+"_")
		} else {
			qs = append(qs, k[:len(k)-1]+"#")
		}
	}
	return qs
}

func rounds(f func(string) int64, qs []string, r int) int64 {
	var t int64
	for i := 0; i < r; i++ {
		for _, q := range qs {
			t += f(q) + 1
		}
	}
	return t
}

func main() {
	set := os.Args[1]
	n, _ := strconv.Atoi(os.Args[2])
	r, _ := strconv.Atoi(os.Args[3])
	qs := queries(keys(set), n)
	var t int64
	switch set {
	case "renkw":
		t = rounds(renkw, qs, r)
	case "jsreserved":
		t = rounds(jsreserved, qs, r)
	case "methods":
		t = rounds(methods, qs, r)
	case "headers":
		t = rounds(headers, qs, r)
	case "json24":
		t = rounds(json24, qs, r)
	case "one":
		t = rounds(one, qs, r)
	}
	fmt.Println(t)
}
