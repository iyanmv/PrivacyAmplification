CXX = g++
CXXFLAGS = -O2 -g -Wall -std=c++17
LIBS = -pthread -lzmq

all: main.cpp
	$(CXX) $(CXXFLAGS) -o LargeBlocksizeExample main.cpp sha3/sha3.c $(LIBS)

clean:
	$(RM) LargeBlocksizeExample
