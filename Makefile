.PHONY: build clean test deps

build:
	dune build

clean:
	dune clean

test:
	dune runtest

deps:
	opam install angstrom faraday logs gluten-lwt-unix
