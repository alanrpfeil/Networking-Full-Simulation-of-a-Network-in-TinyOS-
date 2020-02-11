interface NeighborDiscovery {
	command void run();
	command void print();
	command uint8_t getNumNeighbors();
	command uint8_t* getNeighbors();
	//command void start();
	//event void changed(uint8_t id);
}
