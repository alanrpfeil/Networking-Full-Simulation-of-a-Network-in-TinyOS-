#ifndef LSP_H
#define LSP_H

enum {
	MAX_LSP = 20
};
typedef nx_struct lspLink{
	// header
	nx_uint8_t src;
	nx_uint16_t dest;
	
	// regular packet info; payload
	nx_uint8_t neighbors[20];
	nx_uint8_t costs[20];
	
}lspLink;
#endif