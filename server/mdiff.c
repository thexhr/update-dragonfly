#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <ctype.h>

int 
main(int argc, char **argv)
{
	int fd0, fd1;
	int l0, l1, c;
	char c0, c1;

	if (argc < 2) {
		printf("usage\n");
		exit(1);
	}

	
	if ((fd0 = open(argv[1], O_RDONLY)) < 0 ) {
		printf("Cannot open %s\n", argv[1]);
		return(-1);
	}
	if ((fd1 = open(argv[2], O_RDONLY)) < 0 ) {
		printf("Cannot open %s\n", argv[2]);
		return(-1);
	}

	l0 = l1 =  0;
	l0 = read(fd0, &c0, 1);
	l1 = read(fd1, &c1, 1);
	c = l0;
	while (l0 > 0) {
		if (c0 != c1) {
			if (isprint(c0) && isprint(c1))
				printf("diff at 0x%x: 0x%x (%c) != 0x%x (%c)\n", 
					c,c0,c0, c1,c1);
			else if (isprint(c0) && !isprint(c1))
				printf("diff at 0x%x: 0x%x (%c)\n", 
					c,c0,c0);
			else if (!isprint(c0) && isprint(c1))
				printf("diff at 0x%x:             0x%x (%c)\n", 
					c,c1,c1);
			else
				printf("diff at 0x%x\n", c);
		}
		l0 = read(fd0, &c0, 1);
		l1 = read(fd1, &c1, 1);
		c += l0;
		c += l0;
	}

	close(fd0);
	close(fd1);
	
	return(0);
}

