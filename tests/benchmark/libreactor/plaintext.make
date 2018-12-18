CC     = gcc
PROG   = server
OBJS   = src/setup.o src/main.o
CFLAGS = -std=gnu11 -Wall -O3 -march=native -mtune=native -flto -fuse-linker-plugin -Isrc -I$(INCLUDEDIR)
LDADD  = -lreactor -ldynamic -lclo -L$(LIBDIR)

$(PROG): $(OBJS)
	$(CC) -o $@ $^ $(CFLAGS) $(LDADD)

clean:
	rm -f $(PROG) $(OBJS)
