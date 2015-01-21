// Copyright 2014 Isis Innovation Limited and the authors of InfiniTAM

#include "ITMSceneReconstructionEngine_CUDA.h"
#include "ITMCUDAUtils.h"
#include "../../DeviceAgnostic/ITMSceneReconstructionEngine.h"
#include "../../../Objects/ITMRenderState_VH.h"

using namespace ITMLib::Engine;

template<class TVoxel>
__global__ void integrateIntoScene_device(TVoxel *localVBA, const ITMHashEntry *hashTable, int *noVisibleEntryIDs,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i imgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW);

template<class TVoxel>
__global__ void integrateIntoScene_device(TVoxel *voxelArray, const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i depthImgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW);

__global__ void buildHashAllocAndVisibleType_device(uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords, const float *depth,
	Matrix4f invM_d, Vector4f projParams_d, float mu, Vector2i _imgSize, float _voxelSize, ITMHashEntry *hashTable, float viewFrustum_min,
	float viewFrustrum_max);

__global__ void allocateVoxelBlocksList_device(int *voxelAllocationList, int *excessAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	int *noAllocatedVoxelEntries, int *noAllocatedExcessEntries, uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords);

__global__ void reAllocateSwappedOutVoxelBlocks_device(int *voxelAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	int *noAllocatedVoxelEntries, uchar *entriesVisibleType);

__global__ void setToType3(uchar *entriesVisibleType, int *visibleEntryIDs, int noVisibleEntries);

template<bool useSwapping>
__global__ void buildVisibleList_device(ITMHashEntry *hashTable, ITMHashCacheState *cacheStates, int noTotalEntries,
	int *visibleEntryIDs, int *noVisibleEntries, int *activeEntryIDs, int *noActiveEntries, uchar *entriesVisibleType,
	Matrix4f M_d, Vector4f projParams_d, Vector2i depthImgSize, float voxelSize);

// host methods

template<class TVoxel>
ITMSceneReconstructionEngine_CUDA<TVoxel,ITMVoxelBlockHash>::ITMSceneReconstructionEngine_CUDA(void) 
{
	ITMSafeCall(cudaMalloc((void**)&noVisibleEntries_device, sizeof(int)));
	ITMSafeCall(cudaMalloc((void**)&noActiveEntries_device, sizeof(int)));
	ITMSafeCall(cudaMalloc((void**)&noAllocatedVoxelEntries_device, sizeof(int)));
	ITMSafeCall(cudaMalloc((void**)&noAllocatedExcessEntries_device, sizeof(int)));

	int noTotalEntries = ITMVoxelBlockHash::noVoxelBlocks;
	ITMSafeCall(cudaMalloc((void**)&entriesAllocType_device, noTotalEntries));
	ITMSafeCall(cudaMalloc((void**)&blockCoords_device, noTotalEntries * sizeof(Vector3s)));
}

template<class TVoxel>
ITMSceneReconstructionEngine_CUDA<TVoxel,ITMVoxelBlockHash>::~ITMSceneReconstructionEngine_CUDA(void) 
{
	ITMSafeCall(cudaFree(noVisibleEntries_device));
	ITMSafeCall(cudaFree(noActiveEntries_device));
	ITMSafeCall(cudaFree(noAllocatedVoxelEntries_device));
	ITMSafeCall(cudaFree(noAllocatedExcessEntries_device));

	ITMSafeCall(cudaFree(entriesAllocType_device));
	ITMSafeCall(cudaFree(blockCoords_device));
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMVoxelBlockHash>::AllocateSceneFromDepth(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view, 
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, invM_d;
	Vector4f projParams_d, invProjParams_d;

	ITMRenderState_VH *renderState_vh = (ITMRenderState_VH*)renderState;

	M_d = trackingState->pose_d->M; M_d.inv(invM_d);

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	invProjParams_d = projParams_d;
	invProjParams_d.x = 1.0f / invProjParams_d.x;
	invProjParams_d.y = 1.0f / invProjParams_d.y;

	float mu = scene->sceneParams->mu;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	int *voxelAllocationList = scene->localVBA.GetAllocationList();
	int *excessAllocationList = scene->index.GetExcessAllocationList();
	ITMHashEntry *hashTable = scene->index.GetEntries();
	ITMHashCacheState *cacheStates = scene->useSwapping ? scene->globalCache->GetCacheStates(true) : 0;

	int noTotalEntries = scene->index.noVoxelBlocks;

	int *visibleEntryIDs = renderState_vh->GetVisibleEntryIDs();
	int *activeEntryIDs = renderState_vh->GetActiveEntryIDs();
	uchar *entriesVisibleType = renderState_vh->GetEntriesVisibleType();

	dim3 cudaBlockSizeHV(16, 16);
	dim3 gridSizeHV((int)ceil((float)depthImgSize.x / (float)cudaBlockSizeHV.x), (int)ceil((float)depthImgSize.y / (float)cudaBlockSizeHV.y));

	dim3 cudaBlockSizeAL(256, 1);
	dim3 gridSizeAL((int)ceil((float)noTotalEntries / (float)cudaBlockSizeAL.x));

	dim3 cudaBlockSizeVS(256, 1);
	dim3 gridSizeVS((int)ceil((float)renderState_vh->noVisibleEntries / (float)cudaBlockSizeVS.x));

	float oneOverVoxelSize = 1.0f / (voxelSize * SDF_BLOCK_SIZE);

	ITMSafeCall(cudaMemcpy(noAllocatedVoxelEntries_device, &scene->localVBA.lastFreeBlockId, sizeof(int), cudaMemcpyHostToDevice));
	ITMSafeCall(cudaMemcpy(noAllocatedExcessEntries_device, &scene->index.lastFreeExcessListId, sizeof(int), cudaMemcpyHostToDevice));

	ITMSafeCall(cudaMemset(noVisibleEntries_device, 0, sizeof(int)));
	ITMSafeCall(cudaMemset(noActiveEntries_device, 0, sizeof(int)));

	ITMSafeCall(cudaMemset(entriesAllocType_device, 0, sizeof(unsigned char)* noTotalEntries));
	//ITMSafeCall(cudaMemset(entriesVisibleType, 0, sizeof(unsigned char)* noTotalEntries));

	if (gridSizeVS.x > 0) setToType3 << <gridSizeAL, cudaBlockSizeAL >> > (entriesVisibleType, visibleEntryIDs, renderState_vh->noVisibleEntries);

	buildHashAllocAndVisibleType_device << <gridSizeHV, cudaBlockSizeHV >> >(entriesAllocType_device, entriesVisibleType, 
		blockCoords_device, depth, invM_d, invProjParams_d, mu, depthImgSize, oneOverVoxelSize, hashTable,
		scene->sceneParams->viewFrustum_min, scene->sceneParams->viewFrustum_max);

	allocateVoxelBlocksList_device << <gridSizeAL, cudaBlockSizeAL >> >(voxelAllocationList, excessAllocationList, hashTable,
		noTotalEntries, noAllocatedVoxelEntries_device, noAllocatedExcessEntries_device, entriesAllocType_device, entriesVisibleType, 
		blockCoords_device);

	if (scene->useSwapping)
		buildVisibleList_device<true> << <gridSizeAL, cudaBlockSizeAL >> >(hashTable, cacheStates, noTotalEntries, visibleEntryIDs,
		noVisibleEntries_device, activeEntryIDs, noActiveEntries_device, entriesVisibleType, M_d, projParams_d, depthImgSize, voxelSize);
	else
		buildVisibleList_device<false> << <gridSizeAL, cudaBlockSizeAL >> >(hashTable, cacheStates, noTotalEntries, visibleEntryIDs,
		noVisibleEntries_device, activeEntryIDs, noActiveEntries_device, entriesVisibleType, M_d, projParams_d, depthImgSize, voxelSize);

	if (scene->useSwapping)
	{
		reAllocateSwappedOutVoxelBlocks_device << <gridSizeAL, cudaBlockSizeAL >> >(voxelAllocationList, hashTable, noTotalEntries, 
			noAllocatedVoxelEntries_device, entriesVisibleType);
	}

	ITMSafeCall(cudaMemcpy(&renderState_vh->noActiveEntries, noActiveEntries_device, sizeof(int), cudaMemcpyDeviceToHost));
	ITMSafeCall(cudaMemcpy(&renderState_vh->noVisibleEntries, noVisibleEntries_device, sizeof(int), cudaMemcpyDeviceToHost));

	ITMSafeCall(cudaMemcpy(&scene->localVBA.lastFreeBlockId, noAllocatedVoxelEntries_device, sizeof(int), cudaMemcpyDeviceToHost));
	ITMSafeCall(cudaMemcpy(&scene->index.lastFreeExcessListId, noAllocatedExcessEntries_device, sizeof(int), cudaMemcpyDeviceToHost));
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMVoxelBlockHash>::IntegrateIntoScene(ITMScene<TVoxel, ITMVoxelBlockHash> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
	Vector2i rgbImgSize = view->rgb->noDims;
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, M_rgb;
	Vector4f projParams_d, projParams_rgb;

	ITMRenderState_VH *renderState_vh = (ITMRenderState_VH*)renderState;

	M_d = trackingState->pose_d->M;
	if (TVoxel::hasColorInformation) M_rgb = view->calib->trafo_rgb_to_depth.calib_inv * trackingState->pose_d->M;

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	projParams_rgb = view->calib->intrinsics_rgb.projectionParamsSimple.all;

	float mu = scene->sceneParams->mu; int maxW = scene->sceneParams->maxW;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	Vector4u *rgb = view->rgb->GetData(MEMORYDEVICE_CUDA);
	TVoxel *localVBA = scene->localVBA.GetVoxelBlocks();
	ITMHashEntry *hashTable = scene->index.GetEntries();

	int *activeEntryIDs = renderState_vh->GetActiveEntryIDs();

	dim3 cudaBlockSize(SDF_BLOCK_SIZE, SDF_BLOCK_SIZE, SDF_BLOCK_SIZE);
	dim3 gridSize(renderState_vh->noActiveEntries);

	integrateIntoScene_device << <gridSize, cudaBlockSize >> >(localVBA, hashTable, activeEntryIDs,
		rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
}

// plain voxel array

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMPlainVoxelArray>::AllocateSceneFromDepth(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
}

template<class TVoxel>
void ITMSceneReconstructionEngine_CUDA<TVoxel, ITMPlainVoxelArray>::IntegrateIntoScene(ITMScene<TVoxel, ITMPlainVoxelArray> *scene, const ITMView *view,
	const ITMTrackingState *trackingState, const ITMRenderState *renderState)
{
	Vector2i rgbImgSize = view->rgb->noDims;
	Vector2i depthImgSize = view->depth->noDims;
	float voxelSize = scene->sceneParams->voxelSize;

	Matrix4f M_d, M_rgb;
	Vector4f projParams_d, projParams_rgb;

	M_d = trackingState->pose_d->M;
	if (TVoxel::hasColorInformation) M_rgb = view->calib->trafo_rgb_to_depth.calib_inv * trackingState->pose_d->M;

	projParams_d = view->calib->intrinsics_d.projectionParamsSimple.all;
	projParams_rgb = view->calib->intrinsics_rgb.projectionParamsSimple.all;

	float mu = scene->sceneParams->mu; int maxW = scene->sceneParams->maxW;

	float *depth = view->depth->GetData(MEMORYDEVICE_CUDA);
	Vector4u *rgb = view->rgb->GetData(MEMORYDEVICE_CUDA);
	TVoxel *localVBA = scene->localVBA.GetVoxelBlocks();
	const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo = scene->index.getIndexData();

	dim3 cudaBlockSize(8, 8, 8);
	dim3 gridSize(scene->index.getVolumeSize().x / cudaBlockSize.x, scene->index.getVolumeSize().y / cudaBlockSize.y, scene->index.getVolumeSize().z / cudaBlockSize.z);

	integrateIntoScene_device << <gridSize, cudaBlockSize >> >(localVBA, arrayInfo,
		rgb, rgbImgSize, depth, depthImgSize, M_d, M_rgb, projParams_d, projParams_rgb, voxelSize, mu, maxW);
}

// device functions

template<class TVoxel>
__global__ void integrateIntoScene_device(TVoxel *voxelArray, const ITMPlainVoxelArray::ITMVoxelArrayInfo *arrayInfo,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i depthImgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW)
{
	int x = blockIdx.x*blockDim.x+threadIdx.x;
	int y = blockIdx.y*blockDim.y+threadIdx.y;
	int z = blockIdx.z*blockDim.z+threadIdx.z;

	Vector4f pt_model; int locId;

	locId = x + y * arrayInfo->size.x + z * arrayInfo->size.x * arrayInfo->size.y;

	pt_model.x = (float)(x + arrayInfo->offset.x) * _voxelSize;
	pt_model.y = (float)(y + arrayInfo->offset.y) * _voxelSize;
	pt_model.z = (float)(z + arrayInfo->offset.z) * _voxelSize;
	pt_model.w = 1.0f;

	ComputeUpdatedVoxelInfo<TVoxel::hasColorInformation,TVoxel>::compute(voxelArray[locId], pt_model, M_d, projParams_d, M_rgb, projParams_rgb, mu, maxW, depth, depthImgSize, rgb, rgbImgSize);
}

template<class TVoxel>
__global__ void integrateIntoScene_device(TVoxel *localVBA, const ITMHashEntry *hashTable, int *visibleEntryIDs,
	const Vector4u *rgb, Vector2i rgbImgSize, const float *depth, Vector2i depthImgSize, Matrix4f M_d, Matrix4f M_rgb, Vector4f projParams_d, 
	Vector4f projParams_rgb, float _voxelSize, float mu, int maxW)
{
	Vector3i globalPos;
	int entryId = visibleEntryIDs[blockIdx.x];

	const ITMHashEntry &currentHashEntry = hashTable[entryId];

	if (currentHashEntry.ptr < 0) return;

	globalPos = currentHashEntry.pos.toInt() * SDF_BLOCK_SIZE;

	TVoxel *localVoxelBlock = &(localVBA[currentHashEntry.ptr * SDF_BLOCK_SIZE3]);

	int x = threadIdx.x, y = threadIdx.y, z = threadIdx.z;

	Vector4f pt_model; int locId;

	locId = x + y * SDF_BLOCK_SIZE + z * SDF_BLOCK_SIZE * SDF_BLOCK_SIZE;

	pt_model.x = (float)(globalPos.x + x) * _voxelSize;
	pt_model.y = (float)(globalPos.y + y) * _voxelSize;
	pt_model.z = (float)(globalPos.z + z) * _voxelSize;
	pt_model.w = 1.0f;

	ComputeUpdatedVoxelInfo<TVoxel::hasColorInformation,TVoxel>::compute(localVoxelBlock[locId], pt_model, M_d, projParams_d, M_rgb, projParams_rgb, mu, maxW, depth, depthImgSize, rgb, rgbImgSize);
}

__global__ void buildHashAllocAndVisibleType_device(uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords, const float *depth,
	Matrix4f invM_d, Vector4f projParams_d, float mu, Vector2i _imgSize, float _voxelSize, ITMHashEntry *hashTable, float viewFrustum_min,
	float viewFrustum_max)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x, y = threadIdx.y + blockIdx.y * blockDim.y;

	if (x > _imgSize.x - 1 || y > _imgSize.y - 1) return;

	buildHashAllocAndVisibleTypePP(entriesAllocType, entriesVisibleType, x, y, blockCoords, depth, invM_d,
		projParams_d, mu, _imgSize, _voxelSize, hashTable, viewFrustum_min, viewFrustum_max);
}

__global__ void setToType3(uchar *entriesVisibleType, int *visibleEntryIDs, int noVisibleEntries)
{
	int entryId = threadIdx.x + blockIdx.x * blockDim.x;
	if (entryId > noVisibleEntries - 1) return;
	entriesVisibleType[visibleEntryIDs[entryId]] = 3;
}

__global__ void allocateVoxelBlocksList_device(int *voxelAllocationList, int *excessAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	int *noAllocatedVoxelEntries, int *noAllocatedExcessEntries, uchar *entriesAllocType, uchar *entriesVisibleType, Vector4s *blockCoords)
{
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	int vbaIdx, exlIdx;

	switch (entriesAllocType[targetIdx])
	{
	case 1: //needs allocation, fits in the ordered list
		vbaIdx = atomicSub(&noAllocatedVoxelEntries[0], 1);

		if (vbaIdx >= 0) //there is room in the voxel block array
		{
			Vector4s pt_block_all = blockCoords[targetIdx];

            ITMHashEntry hashEntry;
			hashEntry.pos.x = pt_block_all.x; hashEntry.pos.y = pt_block_all.y; hashEntry.pos.z = pt_block_all.z;
			hashEntry.ptr = voxelAllocationList[vbaIdx];
            hashEntry.offset = 0;

			hashTable[targetIdx] = hashEntry;
		}
		break;

	case 2: //needs allocation in the excess list
		vbaIdx = atomicSub(&noAllocatedVoxelEntries[0], 1);
		exlIdx = atomicSub(&noAllocatedExcessEntries[0], 1);

		if (vbaIdx >= 0 && exlIdx >= 0) //there is room in the voxel block array and excess list
		{
			Vector4s pt_block_all = blockCoords[targetIdx];

            ITMHashEntry hashEntry;
			hashEntry.pos.x = pt_block_all.x; hashEntry.pos.y = pt_block_all.y; hashEntry.pos.z = pt_block_all.z;
			hashEntry.ptr = voxelAllocationList[vbaIdx];
            hashEntry.offset = 0;

			int exlOffset = excessAllocationList[exlIdx];

			hashTable[targetIdx].offset = exlOffset + 1; //connect to child

			hashTable[SDF_BUCKET_NUM * SDF_ENTRY_NUM_PER_BUCKET + exlOffset] = hashEntry; //add child to the excess list

			entriesVisibleType[SDF_BUCKET_NUM * SDF_ENTRY_NUM_PER_BUCKET + exlOffset] = 1; //make child visible
		}

		break;
	}
}

__global__ void reAllocateSwappedOutVoxelBlocks_device(int *voxelAllocationList, ITMHashEntry *hashTable, int noTotalEntries,
	int *noAllocatedVoxelEntries, uchar *entriesVisibleType)
{
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	int vbaIdx;
	ITMHashEntry hashEntry = hashTable[targetIdx];

	if (entriesVisibleType[targetIdx] > 0 && hashEntry.ptr == -1) //it is visible and has been previously allocated inside the hash, but deallocated from VBA
	{
		vbaIdx = atomicSub(&noAllocatedVoxelEntries[0], 1);
		if (vbaIdx >= 0) hashTable[targetIdx].ptr = voxelAllocationList[vbaIdx];
	}
}

template<bool useSwapping>
__global__ void buildVisibleList_device(ITMHashEntry *hashTable, ITMHashCacheState *cacheStates, int noTotalEntries, 
	int *visibleEntryIDs, int *noVisibleEntries, int *activeEntryIDs, int *noActiveEntries, uchar *entriesVisibleType, 
	Matrix4f M_d, Vector4f projParams_d, Vector2i depthImgSize, float voxelSize)
{
	int targetIdx = threadIdx.x + blockIdx.x * blockDim.x;
	if (targetIdx > noTotalEntries - 1) return;

	__shared__ bool shouldPrefix;

	unsigned char hashVisibleType = entriesVisibleType[targetIdx];
	const ITMHashEntry &hashEntry = hashTable[targetIdx];

	shouldPrefix = false;
	__syncthreads();

	if (hashVisibleType >= 2)
	{
		bool isVisibleEnlarged, isVisible;

		if (hashVisibleType == 3)
		{
			checkBlockVisibility<false>(isVisible, isVisibleEnlarged, hashEntry.pos, M_d, projParams_d, voxelSize, depthImgSize);
			if (!isVisible) { entriesVisibleType[targetIdx] = 0; hashVisibleType = 0; }
		}

		if (useSwapping && hashVisibleType == 2)
		{
			checkBlockVisibility<true>(isVisible, isVisibleEnlarged, hashEntry.pos, M_d, projParams_d, voxelSize, depthImgSize);
			entriesVisibleType[targetIdx] = isVisibleEnlarged; hashVisibleType = isVisibleEnlarged;
		}
	}

	if (hashVisibleType > 0) shouldPrefix = true;

	if (useSwapping)
	{
		if (entriesVisibleType[targetIdx] > 0 && cacheStates[targetIdx].cacheFromHost != 2) cacheStates[targetIdx].cacheFromHost = 1;
	}

	__syncthreads();

	if (shouldPrefix)
	{
		int offset = computePrefixSum_device<int>(hashVisibleType > 0, noVisibleEntries, blockDim.x * blockDim.y, threadIdx.x);
		if (offset != -1) visibleEntryIDs[offset] = targetIdx;
	}

	__syncthreads();

	if (shouldPrefix)
	{
		int offset = computePrefixSum_device<int>(hashVisibleType == 1, noActiveEntries, blockDim.x * blockDim.y, threadIdx.x);
		if (offset != -1) activeEntryIDs[offset] = targetIdx;
	}
}

template class ITMLib::Engine::ITMSceneReconstructionEngine_CUDA<ITMVoxel, ITMVoxelIndex>;

