
#include "modelSelector.h"
#include "svmTrainer.h"
#include "HessianIO/hessianIO.h"
#include "HessianIO/parHessianIO.h"
#include <helper_cuda.h>
#include <sys/sysinfo.h>

/**
 * @brief: search the best pair of parameters
 */
bool CModelSelector::GridSearch(const grid &SGrid, vector<vector<float_point> > &v_vDocVector, vector<int> &vnLabel)
{
	bool bReturn = false;

	float_point *pfGamma = SGrid.pfGamma;
	int nNumofGamma = SGrid.nNumofGamma;
	float_point *pfCost = SGrid.pfCost;
	int nNumofC = SGrid.nNumofC;

	int nNumofSample = v_vDocVector.size();
	int *pnPredictedLabel = new int[nNumofSample];
	svm_param param;
	int nNumofFold = 10;//10 means 10-fold cross


	CHessianIOOps::m_nTotalNumofInstance = v_vDocVector.size();
	CGradientStrategy cacheStrategy(v_vDocVector.size());
	cout << "using " << cacheStrategy.GetStrategy() << " caching strategy"<< endl;

	for(int j = 0; j < nNumofGamma; j++)
	{
		param.gamma = pfGamma[j];

		CRBFKernel rbf(pfGamma[j]);//ignore
		CParHessianOp hessianIOOps(&rbf);
		CSVMPredictor svmPredicter(&hessianIOOps);

		PrecomputeKernelMatrix(v_vDocVector, &hessianIOOps);

		//start n-fold-cross-validation, by changing C for SVM
		for(int k = 0; k < nNumofC; k++)
		{
			CSMOSolver s(&hessianIOOps, &cacheStrategy);
			s.m_fPC = s.m_fNC = pfCost[k];

			CSVMTrainer svmTrainer(&s);
			m_pTrainer = &svmTrainer;
			m_pPredictor = &svmPredicter;

			memset(pnPredictedLabel, 0, sizeof(int) * nNumofSample);
			gfNCost = pfCost[k];
			gfPCost = pfCost[k];
			gfGamma = pfGamma[j];
			ofstream writeOut(OUTPUT_FILE, ios::app | ios::out);
			writeOut << "Gamma=" << pfGamma[j] << "; Cost=" << pfCost[k] << endl;

			timespec timeValidS, timeValidE;
			clock_gettime(CLOCK_REALTIME, &timeValidS);
			bool bCrossValidation = CrossValidation(nNumofFold, vnLabel, pnPredictedLabel);
			if(bCrossValidation == false)
			{
				cerr << "can't have valid result in N_fold_cross_validation" << endl;
				continue;
			}
			clock_gettime(CLOCK_REALTIME, &timeValidE);
			long lCrossValidationTime = ((timeValidE.tv_sec - timeValidS.tv_sec) * 1e9 + (timeValidE.tv_nsec - timeValidS.tv_nsec));
			writeOut.close();
			//output n-fold-cross-validation result
			OutputResult(vnLabel, pnPredictedLabel, nNumofSample);

			cout << "total time: " << (double)lCrossValidationTime / 1000000 << "ms" << endl;
		}//end varying C
		//release pinned memory
		cudaFreeHost(CHessianIOOps::m_pfHessianRowsInHostMem);
		delete[] CHessianIOOps::m_pfHessianDiag;
	}//end varying gamma

	delete[] pnPredictedLabel;

	return bReturn;
}

/**
 * @brief: kernel matrix precomputation
 */
void CModelSelector::PrecomputeKernelMatrix(vector<vector<float_point> > &v_vDocVector, CHessianIOOps *hessianIOOps)
{
	//compute Hessian Matrix
	string strHessianMatrixFileName = HESSIAN_FILE;
	string strDiagHessianFileName = HESSIAN_DIAG_FILE;

	int nNumofSample = v_vDocVector.size();

	//initialize Hessian IO operator
	//CLinearKernel RBF(pfGamma[j]);

	int nNumofRowsOfHessianMatrix = v_vDocVector.size();
	//space of row-index-in-file is for improving reading performace
	CHessianIOOps::m_nNumofDimensions = v_vDocVector.front().size();
	CHessianIOOps::m_nTotalNumofInstance = nNumofRowsOfHessianMatrix;

	//cache part of hessian matrix in memory
	struct sysinfo info;
	sysinfo(&info);
	long long nFreeMemInFloat = (info.freeram / sizeof(float_point));
	//memory for storing sample data, both original and transposed forms. That's why we use "2" here.
	long long nMemForSamples = (hessianIOOps->m_nNumofDimensions * (long long)hessianIOOps->m_nTotalNumofInstance * 2);
	nFreeMemInFloat -= nMemForSamples;	//get the number of available memory in the form of number of float
	nFreeMemInFloat *= 0.9;				//use 80% of the memory for caching
	long nNumofHessianRow = (nFreeMemInFloat / nNumofSample);
	assert(nFreeMemInFloat > 0);
	if(nNumofHessianRow > nNumofSample)
	{
		//if the available memory is available to store the whole hessian matrix
		nNumofHessianRow = nNumofSample;
	}
//			if(nNumofHessianRow > 21500)nNumofHessianRow = 21500;
//			assert(nNumofHessianRow == 21500);
/*	long nRAMForRow = RAM_SIZE * 1024;
	nRAMForRow *= 1024;
	nRAMForRow *= 1024;
	nRAMForRow /= sizeof(float_point);
	nNumofHessianRow = (nRAMForRow / nNumofSample);
*/
	if(nNumofHessianRow > nNumofSample)
		nNumofHessianRow = nNumofSample;
	cout << nNumofHessianRow << " rows cached in RAM" << endl;
	long lSizeofCachedHessia = sizeof(float_point) * (long long)nNumofHessianRow * nNumofSample;
	checkCudaErrors(cudaMallocHost((void**)&CHessianIOOps::m_pfHessianRowsInHostMem, sizeof(float_point) * (long long)nNumofHessianRow * nNumofSample));
	memset(CHessianIOOps::m_pfHessianRowsInHostMem, 0, lSizeofCachedHessia);
	CHessianIOOps::m_nNumofCachedHessianRow = nNumofHessianRow;
	CHessianIOOps::m_pfHessianDiag = new float_point[hessianIOOps->m_nTotalNumofInstance];
	//hessianIOOps->m_pfHessianDiagTest = new float_point[hessianIOOps->m_nTotalNumofInstance];

	//pre-compute Hessian Matrix and store the result into a file
	cout << "precomputing kernel matrix...";
	cout.flush();

	timeval t1, t2;
	float_point elapsedTime;
	gettimeofday(&t1, NULL);
	bool bWriteHessian = hessianIOOps->WriteHessian(strHessianMatrixFileName, strDiagHessianFileName, v_vDocVector);
	hessianIOOps->ReadDiagFromHessianMatrix();

	gettimeofday(&t2, NULL);
	elapsedTime = (t2.tv_sec - t1.tv_sec) * 1000.0;
	elapsedTime += (t2.tv_usec - t1.tv_usec) / 1000.0;
	//cout << "Done" << elapsedTime << " ms.\n";
	cout << " Done" << endl;

	if(bWriteHessian == false)
	{
		cerr << "write matrix to file failed" << endl;
		exit(0);
	}
}

/*
 * @brief: n fold cross validation
 * @param: nFold: the number of fold for the cross validation
 */
bool CModelSelector::CrossValidation(const int &nFold, vector<int> &vnLabel, int *&pnPredictedLabel)
{
	bool bReturn = true;

	int nTotalNumofSamples = vnLabel.size();
	//get labels of data
	int *pnLabelAll = new int[nTotalNumofSamples];
	for(int l = 0; l < nTotalNumofSamples; l++)
	{
		if(vnLabel[l] != 1 && vnLabel[l] != -1)
		{
			cerr << "error label" << endl;
			exit(0);
		}
		pnLabelAll[l] = vnLabel[l];
	}

	//check input parameters
	if((nFold < 1) || nTotalNumofSamples < nFold)
	{
		cerr << "error in cross validation: invalid parameters" << endl;
		exit(0);
	}

	//divide the training samples in to n folds. note that the last fold may be larger than other folds.
	int nSizeofFold = 0;
	nSizeofFold = nTotalNumofSamples / nFold;
	int *pnFoldStart = new int[nFold];
	//Initialise the first fold
	pnFoldStart[0] = 0;
	//for the case that there is only one fold
	if(nFold == 1)
	{
		pnFoldStart[1] = 0;
	}
	//start counting the size of each fold
	for(int i = 1; i < nFold; i++)
	{
		pnFoldStart[i] = pnFoldStart[i - 1] + nSizeofFold;
	}

	//during n-fold cross validation, training samples are divided into at most 2 parts
	int *pnSizeofParts = new int[2];

	/* allocate GPU device memory */
	//set default value at
	float_point *pfAlphaAll;
	float_point *pfYiGValueAll;
	pfAlphaAll = new float_point[nTotalNumofSamples];
	pfYiGValueAll = new float_point[nTotalNumofSamples];
	for(int i = 0; i < nTotalNumofSamples; i++)
	{
		//initially, the values of alphas are 0s
		pfAlphaAll[i] = 0;
		//GValue is -y_i, as all alphas are 0s. YiGValue is always -1
		pfYiGValueAll[i] = -pnLabelAll[i];
	}

	/* start n-fold-cross-validation */
	//allocate GPU memory for part of samples that are used to perform training.
	float_point *pfDevAlphaSubset;
	float_point *pfDevYiGValueSubset;
	int *pnDevLabelSubset;

	float_point *pfPredictionResult = new float_point[nTotalNumofSamples];
	for(int i = 0; i < nFold; i++)
	{
		/**************** training *******************/
		//first continual part of sample data
		if(i != 0)
		{
			pnSizeofParts[0] = pnFoldStart[i];
		}
		else
		{
			pnSizeofParts[0] = 0;
		}

		//second continual
		if(i != nFold - 1 || nFold == 1)//nFold == 1 is  for special case, where all samples are for training and testing
		{
			pnSizeofParts[1] = nTotalNumofSamples - pnFoldStart[i + 1];
		}
		else
		{
			pnSizeofParts[1] = 0;
		}

		//get size of training samples
		int nNumofTrainingSamples = 0;
		nNumofTrainingSamples = pnSizeofParts[0] + pnSizeofParts[1];

		//in n-fold-cross validation, the first (n -1) parts have the same size, so we can reuse memory
		if(i == 0 || (i == nFold - 1))
		{
			checkCudaErrors(cudaMalloc((void**)&pfDevAlphaSubset, sizeof(float_point) * nNumofTrainingSamples));
//checkCudaErrors(cudaMallocHost((void**)&pfDevYiGValueSubset, sizeof(float_point) * nNumofTrainingSamples));
			checkCudaErrors(cudaMalloc((void**)&pfDevYiGValueSubset, sizeof(float_point) * nNumofTrainingSamples));
			checkCudaErrors(cudaMalloc((void**)&pnDevLabelSubset, sizeof(int) * nNumofTrainingSamples));
		}
		//set GPU memory
		checkCudaErrors(cudaMemset(pfDevAlphaSubset, 0, sizeof(float_point) * nNumofTrainingSamples));
		checkCudaErrors(cudaMemset(pfDevYiGValueSubset, -1, sizeof(float_point) * nNumofTrainingSamples));
		checkCudaErrors(cudaMemset(pnDevLabelSubset, 0, sizeof(int) * nNumofTrainingSamples));
		//copy training information to GPU for current training
		checkCudaErrors(cudaMemcpy(pfDevAlphaSubset, pfAlphaAll,
								   sizeof(float_point) * pnSizeofParts[0], cudaMemcpyHostToDevice));
		checkCudaErrors(cudaMemcpy(pfDevYiGValueSubset, pfYiGValueAll,
								   sizeof(float_point) * pnSizeofParts[0], cudaMemcpyHostToDevice));
		checkCudaErrors(cudaMemcpy(pnDevLabelSubset, pnLabelAll,
								   sizeof(int) * pnSizeofParts[0], cudaMemcpyHostToDevice));
		//part two
		if(pnSizeofParts[1] != 0)
		{
			checkCudaErrors(cudaMemcpy(pfDevAlphaSubset + pnSizeofParts[0], pfAlphaAll + pnFoldStart[i + 1],
									   sizeof(float_point) * pnSizeofParts[1], cudaMemcpyHostToDevice));
			checkCudaErrors(cudaMemcpy(pfDevYiGValueSubset + pnSizeofParts[0], pfYiGValueAll + pnFoldStart[i + 1],
									   sizeof(float_point) * pnSizeofParts[1], cudaMemcpyHostToDevice));
			checkCudaErrors(cudaMemcpy(pnDevLabelSubset + pnSizeofParts[0], pnLabelAll + pnFoldStart[i + 1],
									   sizeof(int) * pnSizeofParts[1], cudaMemcpyHostToDevice));
		}

		/************** train SVM model **************/
		int nSampleStart1, nSampleEnd1, nSampleStart2, nSampleEnd2;
		if(pnSizeofParts[0] != 0)
		{
			nSampleStart1 = 0;
			nSampleEnd1 = pnSizeofParts[0] - 1;
		}
		else
		{
			nSampleStart1 = -1;
			nSampleEnd1 = -1;
		}
		if(pnSizeofParts[1] != 0)
		{
			nSampleStart2 = pnFoldStart[i + 1];
			nSampleEnd2 = nTotalNumofSamples - 1;
		}
		else
		{
			nSampleStart2 = -1;
			nSampleEnd2 = -1;
		}
		//set data involved in training
		timeval tTraining1, tTraining2;
		float_point trainingElapsedTime;
		gettimeofday(&tTraining1, NULL);
		timespec timeTrainS, timeTrainE;
		clock_gettime(CLOCK_REALTIME, &timeTrainS);

		cout << "training the " << i + 1 << "th classifier";
		cout.flush();

		svm_model model;
		m_pTrainer->SetInvolveTrainingData(nSampleStart1, nSampleEnd1, nSampleStart2, nSampleEnd2);
		bool bTrain = m_pTrainer->TrainModel(model, pfDevYiGValueSubset, pfDevAlphaSubset, pnDevLabelSubset, nNumofTrainingSamples);
		if(bTrain == false)
		{
			cerr << "can't find an optimal classifier" << endl;
			bReturn = false;
			break;
		}

		gettimeofday(&tTraining2, NULL);
		clock_gettime(CLOCK_REALTIME, &timeTrainE);
		long lTrainingTime = ((timeTrainE.tv_sec - timeTrainS.tv_sec) * 1e9 + (timeTrainE.tv_nsec - timeTrainS.tv_nsec));

/*		trainingElapsedTime = (tTraining2.tv_sec - tTraining1.tv_sec) * 1000.0;
		trainingElapsedTime += (tTraining2.tv_usec - tTraining1.tv_usec) / 1000.0;
		cout << "training time: " << trainingElapsedTime << " ms v.s. " << lTrainingTime / 1000000 << " ms" << endl;;
		cout << "updating alpha: " << nTimeOfUpdateAlpha / 1000 << " ms."<< endl;
		nTimeOfUpdateAlpha = 0;
		cout << "select 1st: " << nTimeOfSelect1stSample / 1000 << " ms."<< endl;
		//nTimeOfSelect1stSample = 0;
		cout << "select 2nd: " << nTimeOfSelect2ndSample / 1000 << " ms."<< endl;
		//nTimeOfSelect2ndSample = 0;
		cout << "updating YiF: " << nTimeOfUpdateYiFValue / 1000 << " ms."<< endl;
		nTimeOfUpdateYiFValue = 0;
		cout << "get hessian: " << nTimeofGetHessian / 1000 << " ms." << endl;
		nTimeofGetHessian = 0;
		cout << "loop: " << nTimeOfLoop / 1000000 << " ms." << endl;
		nTimeOfLoop = 0;
		cout << "preparation: " << nTimeOfPrep / 1000000 << " ms." << endl;
		nTimeOfPrep = 0;
		cout << "IO timer: " << lIO_timer / 1000000 << " ms" << endl;

		cout << "GetHessian timer: " << lGetHessianRowTime / 1000000 << " ms" << endl;
		cout << "IO counter: " << lIO_counter << " v.s GetHessianRow counter: " << lGetHessianRowCounter << endl;
		lIO_counter = 0;
		lGetHessianRowCounter = 0;

		cout << "Ram " << lRamHitCount << "; SSD " << lSSDHitCount << endl;
		lRamHitCount = 0;
		lSSDHitCount = 0;

		cout << "get: " << lCountNormal << "; latest: " << lCountLatest << endl;
		lCountNormal = 0;
		lCountLatest = 0;
*/

		/******************** prediction *******************/
		//get the size of a fold for testing
		int nNumofTestingSample = 0;
		if(i != nFold - 1)
			nNumofTestingSample = pnFoldStart[i + 1] - pnFoldStart[i];
		else
			nNumofTestingSample = nTotalNumofSamples - pnFoldStart[i];

		//get testing sample id
		int *pnTestSampleId;
		if(i == 0 || (i == nFold - 1))
		{
			pnTestSampleId = new int[nNumofTestingSample];
		}
		for(int j = 0; j < nNumofTestingSample; j++)
		{
			pnTestSampleId[j] = pnFoldStart[i] + j;
		}

		timespec timeClassificationS, timeClassificationE;
		clock_gettime(CLOCK_REALTIME, &timeClassificationS);

		cout << "performing classification...";
		//set data involve in prediction
		m_pPredictor->SetInvolvePredictionData(pnTestSampleId[0], pnTestSampleId[nNumofTestingSample - 1]);
		//perform prediction
		float_point *pfPartialPredictionResult;
		pfPartialPredictionResult = m_pPredictor->Predict(&model, pnTestSampleId, nNumofTestingSample);
		cout << " Done"<< endl;
		clock_gettime(CLOCK_REALTIME, &timeClassificationE);

		//copy partial result to global result
		for(int j = 0; j < nNumofTestingSample; j++)
		{
			pfPredictionResult[pnFoldStart[i] + j] = pfPartialPredictionResult[j];
		}

		//for comparing the results of the other gpu svm
		int nCorrect = 0;
		for(int j = 0; j < nNumofTestingSample; j++)
		{
			if(pfPartialPredictionResult[j] > 0 && pnLabelAll[pnFoldStart[i] + j] > 0)
				nCorrect++;
			else if(pfPartialPredictionResult[j] < 0 && pnLabelAll[pnFoldStart[i] + j] < 0)
				nCorrect++;
		}
		long lClassificationTime = ((timeClassificationE.tv_sec - timeClassificationS.tv_sec) * 1e9 +
									(timeClassificationE.tv_nsec - timeClassificationS.tv_nsec));

		delete[] pfPartialPredictionResult; //as memory is allocated during prediction
		//release memory, in the first (nFold - 2) iterations, the space of pnTestSampleId can be reused
		if(i >= (nFold - 2))
		{
			delete[] pnTestSampleId;
		}
		DestroySVMModel(model);
	}

	//calculate classification label
	for(int i = 0; i < nTotalNumofSamples; i++)
	{
		if(pfPredictionResult[i] > 0)
		{
			pnPredictedLabel[i] = 1;
		}
		else
		{
			pnPredictedLabel[i] = -1;
		}
	}

	checkCudaErrors(cudaFree(pfDevAlphaSubset));
	checkCudaErrors(cudaFree(pnDevLabelSubset));
	checkCudaErrors(cudaFree(pfDevYiGValueSubset));
//checkCudaErrors(cudaFreeHost(pfDevYiGValueSubset));

	delete[] pfAlphaAll;
	delete[] pfYiGValueAll;

	delete[] pfPredictionResult;
	delete[] pnSizeofParts;

	delete[] pnFoldStart;
	return bReturn;
}

/*
 * @brief: output prediction result (e.g., accuracy, recall, precision etc.)
 * @param: pnOriginalLabel: label of training samples
 * @param: pnPredictedLabel: label assigned by SVM
 */
bool CModelSelector::OutputResult(vector<int> &pnOriginalLabel, int *pnPredictedLabel, int nSizeofSample)
{
	bool bReturn = false;
	int nCorrect = 0, nTrueP = 0, nFalseP = 0, nFalseN = 0, nTrueN = 0;
	for(int i = 0; i < nSizeofSample; i++)
    {
		if((pnPredictedLabel[i] == 1 && pnOriginalLabel[i] == 1) || (pnPredictedLabel[i] == -1 && pnOriginalLabel[i] == -1))
		{
			nCorrect++;
		}

		if(pnPredictedLabel[i] == 1 && pnOriginalLabel[i] == 1)
		{
			nTrueP++;
		}
		else if(pnPredictedLabel[i] == -1 && pnOriginalLabel[i] == 1)
		{
			nFalseN++;
		}
		else if(pnPredictedLabel[i] == 1 && pnOriginalLabel[i] == -1)
		{
			nFalseP++;
		}
		else if(pnPredictedLabel[i] == -1 && pnOriginalLabel[i] == -1)
		{
			nTrueN++;
		}
		else
		{
			cout << "error in output result: " << pnPredictedLabel[i] << " and " << pnOriginalLabel[i]
			     << " are not equal to +1 or -1" << endl;
		}
    }

	double dPrecision = (double)nTrueP / (nTrueP + nFalseP);
	double dRecall = (double)nTrueP / (nFalseN + nTrueP);

	cout << (double)nCorrect / nSizeofSample << " precision: " << dPrecision << " recall: " << dRecall << endl;

/*	ofstream writeOut(OUTPUT_FILE, ios::app | ios::out);
	writeOut << "true positive: " << nTrueP << "; true negative: " << nTrueN
			 << "; false positive: " << nFalseP << "; false negative: " << nFalseN << endl;
	writeOut << (double)nCorrect / nSizeofSample << " precision: " << dPrecision
				<< " recall: " << dRecall << endl;
	writeOut.close();
*/
	return bReturn;
}

/*
 * @brief: destroy svm model
 */
bool CModelSelector::DestroySVMModel(svm_model &model)
{
	bool bReturn = true;

	delete[] model.label;
	delete[] model.pnIndexofSV;
	delete[] model.rho;
	delete[] model.sv_coef[0];
	delete[] model.sv_coef[1];
	delete[] model.sv_coef[2];
	delete[] model.sv_coef;

	return bReturn;
}
