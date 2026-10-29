The real `Net` (compiler.md, "Stage 11a", "`Net`"): TCP through the
system, each wait the scheduler's, so a server's connections are served
at once in tasks of their own. A server that waits in
`Net.accept_until(l, Signal.term)` stops accepting when it's sent
SIGTERM, and what's in flight finishes, under the cleanup deadline.

This one answers each connection with what it was sent, a second later
if that was "slow", on the port it's given:

  $ cat > echo.ren <<'END'
  > // answers each connection with what it was sent, a second later if it
  > // was "slow", until SIGTERM
  > fn handle(c: Conn) ! NetError uses Net, Clock, Console =
  >   let req = try Net.read(c, 100)
  >   match attempt Str.from_utf8(req)
  >     Ok(text) => Console.error("got ".concat(text))
  >     Err(_) => Console.error("got bytes")
  >   if req == "slow".bytes() then Clock.sleep(Duration.seconds(1))
  >   try Net.write(c, req)
  >   Net.close(c)
  > 
  > // the port it's given, in digits
  > fn port() -> Int uses Os =
  >   let b = Os.args()[0].bytes()
  >   var n = 0
  >   for i in 0..b.len()
  >     n = n * 10 + b.at(i) - 48
  >   n
  > 
  > pub fn main() ! NetError uses Net, Clock, Console, Os, Async =
  >   let l = try Net.listen(Addr { host: "127.0.0.1", port: port() })
  >   try Async.scope fn(s) =>
  >     var open = true
  >     while open
  >       match try Net.accept_until(l, Signal.term)
  >         Some(c) =>
  >           s.spawn fn() =>
  >             match attempt handle(c)
  >               Ok(_) => ()
  >               Err(_) => Console.error("a request failed")
  >         None => open = false
  >   print("stopped")
  > END

A client, in Python, which waits for the server to listen, sends its
message and prints the answer; given a third argument, it says
`refused` if nothing listens:

  $ cat > client.py <<'END'
  > import socket, sys, time
  > port, msg = int(sys.argv[1]), sys.argv[2]
  > s = None
  > for _ in range(200):
  >     try:
  >         s = socket.create_connection(("127.0.0.1", port))
  >         break
  >     except ConnectionRefusedError:
  >         if len(sys.argv) > 3: print("refused"); sys.exit(0)
  >         time.sleep(0.05)
  > s.sendall(msg.encode())
  > got = b""
  > while True:
  >     b = s.recv(100)
  >     if not b: break
  >     got += b
  > print(got.decode())
  > END

A free port, and the server on it, in the background:

  $ port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  $ ren run echo.ren -- $port > out 2>&1 &
  $ server=$!
  $ timeout 10 python3 client.py $port hello
  hello

A slow request is in flight when SIGTERM comes: the server stops
accepting, the request still gets its answer, and the server ends as
`main` does, with 0:

  $ timeout 10 python3 client.py $port slow > slow.out &
  $ for i in $(seq 200); do grep -q 'got slow' out && break; sleep 0.05; done
  $ kill -TERM $server; wait $server; echo "exit $?"
  exit 0
  $ wait; cat slow.out
  slow
  $ timeout 10 python3 client.py $port again refused
  refused
  $ cat out
  got hello
  got slow
  stopped

A program that doesn't wait for the signal is cancelled by it: its
`finally`s run, and it exits with 143, as one SIGTERM killed would:

  $ cat > sleeper.ren <<'END'
  > dep Tidy =
  >   nothing: fn()
  > 
  > handler tidy() for Tidy uses Console =
  >   finally(r) =>
  >     print("tidied")
  >     try r
  >   nothing() => ()
  > 
  > fn main() uses Clock, Console =
  >   with tidy() in
  >     print("asleep")
  >     Clock.sleep(Duration.minutes(1))
  > END
  $ ren run sleeper.ren > out 2>&1 &
  $ sleeper=$!
  $ for i in $(seq 200); do grep -q 'asleep' out && break; sleep 0.05; done
  $ kill -TERM $sleeper; wait $sleeper; echo "exit $?"
  exit 143
  $ cat out
  asleep
  tidied

A run of the server is recorded, each `Net` call a call to the world,
one its task waited in written in two lines, and the polls that ended
those waits; replaying it prints what the run printed, with no network:

  $ ren run --record net.journal echo.ren -- $port > out 2>&1 &
  $ server=$!
  $ timeout 10 python3 client.py $port hello
  hello
  $ kill -TERM $server; wait $server; echo "exit $?"
  exit 0
  $ sed "s/$port/PORT/" net.journal
  # ren journal 2 · echo.ren · deps: Clock Console Net Os
  1 main Os.args() → ["PORT"]
  2 main Net.listen(Addr { host: "127.0.0.1", port: PORT }) → Ok(1)
  3 main Net.accept_until(1, 15) …
  4 poll main
  5 main → Ok(Some(2))
  6 main Net.accept_until(1, 15) …
  7 main/main:0 Net.read(2, 100) → Ok("hello")
  8 main/main:0 Console.error("got hello")
  9 main/main:0 Net.write(2, "hello")
  10 main/main:0 Net.close(2)
  11 poll main
  12 main → Ok(None)
  13 main Console.write("stopped")
  14 main exit 0
  $ ren replay net.journal
  got hello
  stopped
  replayed 9 calls: nothing touched the disk, and nothing ran
